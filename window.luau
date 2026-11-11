--!nonstrict
local wt = require("./worktrunk")
local view = require("./view")
local visualize = require("./visualize")
local budget = require("./budget")
local oplog = require("./oplog")
local omplink = require("./omplink")
local Prefs = require("./prefs")

local cache = {}
local inflight = {}
-- Helper liveness probes: job id -> true while `kill -0` runs; dead[id] once it failed.
local probing, dead = {}, {}
local rendered = {}
local collapsed = {}
-- Parent worktrees whose sub-worktrees are folded away: path -> true. In memory, like `collapsed`.
local folded = {}
local confirmation
-- The toast with a button the panel is showing (see notify): { n, at, text, sub, tone, action, label }.
local notice
local NOTICE_KEEP_S = 6
local problem
local lastRefresh = -15000
-- Whether ↻ is spinning for an explicit refresh.
local spinning = false
local sequence = 0
-- The Linear CLI's workspace, for projects without one of their own: nil until
-- looked up, false when unavailable (↻ tries again).
local linearDefault
-- Defined after forms(); openForm starts it.
local watchForms
-- Defined with the coordination rails; refreshes call them.
local railsAfterListing, railsAfterLinks, railsAfterPullRequests, railsAfterSwitch
-- Defined with the tick; every event checks it.
local ensureTicking

local function records(key)
	local value = tern.kv.get(key)
	if value == nil then return {} end
	assert(type(value) == "table", "Overseer storage is invalid: " .. key)
	return value
end

local function projects()
	return records("projects")
end

local function projectById(id)
	for _, project in projects() do
		if project.id == id then return project end
	end
	return nil
end

local function localHost(cx)
	return cx.hosts:current().kind == "local"
end

local function requireLocal(cx)
	if localHost(cx) then return true end
	cx:toast("error", "Local host required", "Switch to the local host.")
	return false
end

-- Keep variable labels short without cutting a UTF-8 character.
local function notificationLabel(label)
	if utf8.len(label) <= 32 then return label end
	return label:sub(1, utf8.offset(label, 32) - 1) .. "…"
end

local function report(cx, text, title)
	problem = tostring(text)
	tern.log.warn(problem)
	local description = if #problem <= 40 and not problem:find("[\r\n]")
		then problem else "See Tern’s log for details."
	cx:toast("error", title or "Action failed", description)
end

local function sessionsById(cx)
	local result = {}
	for _, session in cx.sessions:list() do result[tostring(session.id)] = session end
	return result
end

-- `bindings` lets a caller that checks many worktrees read the store once.
local function boundSession(path, sessions, bindings)
	local binding = (bindings or records("sessions"))[path]
	if binding then
		local session = sessions[tostring(binding.id)]
		if session and session.host == binding.host then return session end
	end
	return nil
end

local function activeWorktree(cx)
	local current = cx.sessions:current()
	for path, binding in records("sessions") do
		if binding.id == current.id and binding.host == current.host then
			local project = projectById(binding.project)
			if project then return project, { path = path } end
		end
	end
	return nil, nil
end

local function removing(path, jobs)
	for _, job in jobs or records("jobs") do
		if job.kind == "remove" and job.path == path then return true end
	end
	return false
end

-- Deletions being checked before they start or before their changes are
-- shown: path -> request. In memory only; a reload just drops the check.
local removalChecks = {}

-- Creations' progress, read from their setup tab (see trackCreations): job
-- id -> { step, asking, needsYou, quiet, changedAt, ... }. In memory only.
local progress = {}

-- Agent CLIs recognised in terminals, by program name.
local AGENTS = {
	omp = true, pi = true, claude = true, codex = true, opencode = true, gemini = true,
	aider = true, amp = true, ["cursor-agent"] = true, crush = true, goose = true,
}

-- Whether a shell command line runs an agent CLI, e.g. "omp", "cd x && claude",
-- "FOO=1 /usr/local/bin/codex --resume".
local function runsAgent(line)
	for segment in string.gmatch(line, "[^;&|]+") do
		for word in string.gmatch(segment, "%S+") do
			if not string.find(word, "=", 1, true) then
				if AGENTS[string.match(word, "([^/]+)$")] then return true end
				break
			end
		end
	end
	return false
end

-- Agent turns that ended out of sight: pane id (string) -> "done" | "failed".
-- Kept in kv so a reload doesn't forget them; cleared once the pane's tab is
-- shown, its agent starts again, or the pane closes.
local function finishedAgents()
	return records("agents-finished")
end

local function setFinished(pane, outcome)
	local finished = finishedAgents()
	local key = tostring(pane)
	if finished[key] == outcome then return false end
	finished[key] = outcome
	tern.kv.set("agents-finished", finished)
	return true
end

-- Which state shows when a tab or session holds agents in several: the one
-- that most needs you.
local AGENT_RANK = { waiting = 4, failed = 3, done = 2, working = 1 }

-- Agent activity in this window, per session id (as a string), per tab id
-- and per pane id: "waiting" (it asked you something), "failed" or "done"
-- (its turn ended while you looked elsewhere), or "working".
-- Native agent blocks such as omp report their state;
-- their `busy` stays set while they sit idle, so it isn't consulted for them.
-- Agent CLIs in plain terminals only report progress, which Tern exposes as
-- `busy` (a CLI that hasn't reported progress yet counts as busy while it runs).
-- One callback's view of the window's panes, tabs and agents, so a draw
-- fetches each list once. A callback gets a fresh `cx`, so keying by it
-- scopes the snapshot to one; the age limit keeps it honest should a `cx`
-- ever be reused.
local SNAPSHOT_MS = 100
local snapshots = setmetatable({}, { __mode = "k" })

-- Agents' states. cx.agents:list() takes 7 to 20 ms (measured in 2.4.3; it
-- also returns every agent's last reply), while the pane list takes 0.1 ms and already says which
-- agent blocks exist and where. So states come from agent_state events, and
-- the full list is only read for agents no event has covered yet (those open
-- before this load) and every AGENT_RECONCILE_MS, in case an event was missed.
-- A pane the full list didn't report is recorded as false.
local AGENT_RECONCILE_MS = 30000
local agentStates = {}
local agentCwds = {}
local agentsListedAt = -AGENT_RECONCILE_MS

local function agentBlocks(cx, panes)
	local stale = tern.now() - agentsListedAt >= AGENT_RECONCILE_MS
	for _, pane in panes do
		if stale then break end
		if pane.kind == "agent" and agentStates[pane.pane] == nil then stale = true end
	end
	if stale then
		agentStates, agentCwds = {}, {}
		for _, pane in panes do
			if pane.kind == "agent" then agentStates[pane.pane] = false end
		end
		for _, agent in cx.agents:list() do
			agentStates[agent.pane], agentCwds[agent.pane] = agent.state, agent.cwd
		end
		agentsListedAt = tern.now()
	end
	local list = {}
	for _, pane in panes do
		local state = pane.kind == "agent" and agentStates[pane.pane]
		if state then
			local cwd = if pane.cwd and pane.cwd ~= "" then pane.cwd else agentCwds[pane.pane]
			table.insert(list, { pane = pane.pane, state = state, cwd = cwd })
		end
	end
	return list
end

local function snapshot(cx)
	local found = snapshots[cx]
	if not found or tern.now() - found.at > SNAPSHOT_MS then
		local panes = cx.session:panes()
		found = { panes = panes, tabs = cx.session:tabs(), agents = agentBlocks(cx, panes), at = tern.now() }
		snapshots[cx] = found
	end
	return found
end

local function agentActivity(cx)
	local seen = snapshot(cx)
	local tabSession = {}
	for _, tab in seen.tabs do tabSession[tab.id] = tostring(tab.session) end
	local activity = { sessions = {}, tabs = {}, panes = {} }
	local function mark(pane, tab, state)
		activity.panes[pane] = state
		local session = tabSession[tab] or ""
		if (AGENT_RANK[activity.sessions[session]] or 0) < AGENT_RANK[state] then activity.sessions[session] = state end
		if (AGENT_RANK[activity.tabs[tab]] or 0) < AGENT_RANK[state] then activity.tabs[tab] = state end
	end
	local finished = finishedAgents()
	local panesById = {}
	for _, pane in seen.panes do panesById[pane.pane] = pane end
	for _, agent in seen.agents do
		local state = if agent.state == "waiting_input" then "waiting"
			elseif agent.state == "working" then "working"
			else finished[tostring(agent.pane)]
		local info = state and panesById[agent.pane]
		if info and info.tab then mark(agent.pane, info.tab, state) end
	end
	for _, pane in seen.panes do
		if pane.kind ~= "agent" and not activity.panes[pane.pane] and pane.busy and pane.running
			and pane.tab and runsAgent(pane.running.line) then
			mark(pane.pane, pane.tab, "working")
		end
	end
	return activity
end

-- What a tab row is called: the name the user gave the tab, else the title of
-- the pane doing its work. The focused pane is often a plugin block, such as
-- this navigator, so terminals and agents are preferred over plugin blocks.
local function tabRows(cx, activity)
	local seen = snapshot(cx)
	local panesByTab = {}
	for _, pane in seen.panes do
		if pane.tab then
			panesByTab[pane.tab] = panesByTab[pane.tab] or {}
			table.insert(panesByTab[pane.tab], pane)
		end
	end
	local agentPanes = {}
	for _, agent in seen.agents do
		if agent.state ~= "exited" then agentPanes[agent.pane] = true end
	end
	local rows = {}
	for _, tab in seen.tabs do
		local panes = panesByTab[tab.id] or {}
		local chosen, hasAgent, agentPane = nil, false, nil
		for _, pane in panes do
			if pane.kind == "agent" then hasAgent = true end
			if agentPanes[pane.pane] and not agentPane then agentPane = pane.pane end
		end
		for _, pane in panes do
			if pane.pane == tab.pane and pane.kind ~= "plugin" then chosen = pane; break end
		end
		if not chosen then
			for _, pane in panes do
				if pane.kind == "terminal" or pane.kind == "agent" then chosen = pane; break end
			end
		end
		if not chosen then
			for _, pane in panes do
				if pane.kind ~= "plugin" then chosen = pane; break end
			end
		end
		local title = chosen and chosen.title or tab.title
		if (not title or title == "") and chosen then
			title = chosen.running and chosen.running.line or chosen.program
		end
		local key = tostring(tab.session)
		rows[key] = rows[key] or {}
		table.insert(rows[key], {
			id = tab.id, pane = tab.pane, agentPane = agentPane,
			name = if tab.name and tab.name ~= "" then tab.name elseif title and title ~= "" then title else "Terminal",
			agent = activity.tabs[tab.id],
			-- An agent block keeps its tab busy even while idle; its state says more.
			busy = tab.busy and not hasAgent,
		})
	end
	return rows
end

-- The first Linear-style ticket id in a branch name: feature/ENG-123-fix → ENG-123.
-- Uppercase only, so names like chore/stage-1 aren't mistaken for tickets.
local function ticketOf(branch)
	return branch and string.match(branch, "%f[%w](%u[%u%d]*%-%d+)%f[%W]")
end

-- The worktree's Linear ticket and its link, in the project's workspace or the CLI's.
local function ticketFor(project, worktree)
	local workspace = project.linear or linearDefault
	local id = workspace and not worktree.is_main and ticketOf(worktree.branch)
	if not id then return nil end
	return { id = id, url = "https://linear.app/" .. workspace .. "/issue/" .. id }
end

-- Sub-worktrees. A branch's `overseer-parent` link (entry.parents) names a
-- branch; a worktree's owner is the top of that chain among the project's
-- listed worktrees, so nesting is one level deep. A link to a branch without
-- a listed worktree, a primary checkout as the child, or a cycle leaves the
-- worktree on top. Returns path -> owner path.
local function owners(entry)
	local result = {}
	if not entry or not entry.worktrees then return result end
	local parents = entry.parents or {}
	local byBranch = {}
	for _, worktree in entry.worktrees do
		if worktree.branch then byBranch[worktree.branch] = worktree end
	end
	for _, worktree in entry.worktrees do
		if worktree.branch and not worktree.is_main then
			local owner, branch, seen = nil, parents[worktree.branch], { [worktree.branch] = true }
			while branch do
				if seen[branch] then owner = nil; break end
				local parent = byBranch[branch]
				if not parent then break end
				owner = parent
				if parent.is_main then break end
				seen[branch] = true
				branch = parents[branch]
			end
			if owner then result[worktree.path] = owner.path end
		end
	end
	return result
end

-- Coordination rails (opt-in per repository; see wt.coordination). Overseer
-- tells a worktree's overseer session (an agent in one of its tabs) what
-- happens in its family of sub-worktrees, handing it over with cx.agents:ask.
-- Kept in kv "rails", keyed by worktree path unless noted; times are os.time()
-- seconds, so they survive restarts:
--   queue    messages waiting for the worktree's overseer session or the rate limit
--   unread   messages delivered since you last looked at the worktree's session
--   sentAt   per pane id: when that session last got a message
--   checkin  when an agent turn last ended in the worktree
--   told     what its parent was already told: waiting, failed, pr ("number@head")
local function railsState()
	local state = records("rails")
	for _, key in { "queue", "unread", "sentAt", "checkin", "told" } do
		if type(state[key]) ~= "table" then state[key] = {} end
	end
	return state
end

-- macOS reaches /tmp, /var and /etc through /private; Worktrunk reports the
-- resolved path and agents may report either, so both compare without it.
local function comparable(path)
	local rest = string.match(path, "^/private(/[^/]+)")
	if rest == "/tmp" or rest == "/var" or rest == "/etc" then return string.sub(path, 9) end
	return path
end

-- This window's running agent blocks per listed worktree path, matched by
-- working directory (the deepest worktree containing it).
local function worktreeAgents(cx)
	local paths = {}
	for _, entry in cache do
		for _, worktree in (entry.worktrees or {}) do table.insert(paths, worktree.path) end
	end
	local byPath = {}
	for _, agent in snapshot(cx).agents do
		if agent.state ~= "exited" and type(agent.cwd) == "string" then
			local best, cwd = nil, comparable(agent.cwd)
			for _, path in paths do
				local root = comparable(path)
				if (cwd == root or string.sub(cwd, 1, #root + 1) == root .. "/") and (not best or #path > #best) then
					best = path
				end
			end
			if best then
				byPath[best] = byPath[best] or {}
				table.insert(byPath[best], agent)
			end
		end
	end
	return byPath
end

-- The pane of a worktree's overseer session: its `overseer-lead` while that
-- agent runs here, else its only running agent, else nil.
local function leadOf(entry, worktree, agents)
	local live = agents[worktree.path] or {}
	local lead = worktree.branch and entry and entry.leads and entry.leads[worktree.branch]
	for _, agent in live do
		if tostring(agent.pane) == lead then return agent.pane end
	end
	return if #live == 1 then live[1].pane else nil
end

local function ago(seconds)
	local minutes = math.floor((os.time() - seconds) / 60)
	if minutes < 1 then return "just now" end
	if minutes < 60 then return tostring(minutes) .. "m ago" end
	local hours = math.floor(minutes / 60)
	return if hours < 48 then tostring(hours) .. "h ago" else tostring(math.floor(hours / 24)) .. "d ago"
end

local function model(cx)
	local sessions = sessionsById(cx)
	local names = records("worktree-names")
	local bindings, jobs = records("sessions"), records("jobs")
	local iceboxOn = Prefs.get().icebox
	-- Ice Box off: parked worktrees show in place; their marks stay for turning it back on.
	local icebox = if iceboxOn then records("icebox") else {}
	local showIcebox = tern.kv.get("show-icebox") ~= false
	local activity = agentActivity(cx)
	local tabs = tabRows(cx, activity)
	local agents = worktreeAgents(cx)
	local rails = railsState()
	local seen = false
	-- Creations in progress, by project and branch.
	local creating = {}
	for id, job in jobs do
		if job.kind == "create" and job.branch and job.project then
			local state = progress[id] or {}
			creating[job.project] = creating[job.project] or {}
			creating[job.project][job.branch] = {
				pane = job.pane, label = job.displayName or job.branch, step = state.step,
				elapsed = math.max(0, os.time() - (job.started or os.time())),
				needsYou = state.needsYou == true, asking = state.asking == true, quiet = state.quiet,
			}
		end
	end
	local result = {
		projects = {}, collapsed = collapsed, confirmation = confirmation,
		showIcebox = showIcebox, iceboxEnabled = iceboxOn, refreshing = spinning,
		-- Kept a little past the toast's own 5.2 s, then dropped from the view.
		notice = if notice and os.time() - notice.at < NOTICE_KEEP_S then notice else nil,
	}
	local current = cx.sessions:current()
	for _, project in projects() do
		local entry = cache[project.id]
		-- Agent coordination is opt-in per repository; off, none of its marks show.
		local coordinating = entry ~= nil and entry.coordination == true
		local row = {
			id = project.id, name = project.name, path = project.path, base = project.base,
			loading = not entry or entry.loading, error = entry and entry.error, worktrees = {}, hiddenIced = 0,
			total = entry and entry.worktrees and #entry.worktrees or 0,
			coordination = coordinating, coordinationKnown = entry ~= nil and entry.coordination ~= nil,
		}
		local ownerOf = owners(entry)
		local items, byPath = {}, {}
		for _, worktree in (entry and entry.worktrees or {}) do
			local item = table.clone(worktree)
			item.deleting = removing(worktree.path, jobs)
			item.checking = removalChecks[worktree.path] ~= nil
			item.displayName = names[project.id] and names[project.id][worktree.path]
			item.pr = not worktree.is_main and worktree.branch and entry.prs and entry.prs[worktree.branch] or nil
			item.ticket = ticketFor(project, worktree)
			item.parentLink = worktree.branch and entry.parents and entry.parents[worktree.branch] or nil
			local session = boundSession(worktree.path, sessions, bindings)
			item.session, item.tabs = session, session and tabs[tostring(session.id)] or {}
			item.agent = session and activity.sessions[tostring(session.id)]
			item.active = session ~= nil and session.id == current.id
			if item.active then result.activePath = worktree.path end
			item.iced = not worktree.is_main and icebox[project.id] ~= nil and icebox[project.id][worktree.path] == true
			item.iceboxEnabled = iceboxOn
			item.coordination = coordinating
			item.lead = if coordinating then leadOf(entry, worktree, agents) else nil
			item.agentCount = #(agents[worktree.path] or {})
			-- Worktrunk lists a new worktree as soon as its directory exists, while
			-- its setup may still be running.
			item.creating = worktree.branch and creating[project.id] and creating[project.id][worktree.branch] or nil
			if item.creating then item.creating.listed = true end
			-- Looking at a worktree's session is reading what Overseer told it.
			if item.active and rails.unread[worktree.path] then
				rails.unread[worktree.path], seen = nil, true
			end
			item.unread = if coordinating then rails.unread[worktree.path] else nil
			table.insert(items, item)
			byPath[worktree.path] = item
		end
		-- Sub-worktrees go under their owner, Ice Box ones last. An iced owner
		-- parks its sub-worktrees with it; the active one always shows.
		for _, item in items do
			local owner = ownerOf[item.path] and byPath[ownerOf[item.path]]
			if owner then
				owner.family = owner.family or {}
				table.insert(owner.family, item)
				if item.active then owner.activeChild = true end
				local checkin = rails.checkin[item.path]
				-- Wall-clock seconds only (values from before that change are ignored).
				item.checkin = if coordinating and type(checkin) == "number" and checkin > 1e9 then ago(checkin) else nil
			end
		end
		-- The overseer badge marks where Overseer's messages for a family land:
		-- the parent's session. A sub-worktree's session still gets its parent's
		-- moves and your briefs, but needs no badge; with several sessions, the
		-- one without "Make overseer session" in its menu is it.
		for _, item in items do
			for _, tab in item.tabs do
				tab.lead = item.lead ~= nil and tab.agentPane == item.lead and item.family ~= nil
				tab.canLead = coordinating and tab.agentPane ~= nil and tab.agentPane ~= item.lead and item.agentCount > 1
			end
		end
		if seen then tern.kv.set("rails", rails) end
		local iced = {}
		for _, item in items do
			if not ownerOf[item.path] then
				local shown, shownIced = {}, {}
				for _, child in (item.family or {}) do
					local parked = child.iced or item.iced
					if not parked then
						table.insert(shown, child)
					elseif showIcebox or child.active then
						table.insert(shownIced, child)
					else
						row.hiddenIced += 1
					end
					if (AGENT_RANK[child.agent] or 0) > (AGENT_RANK[item.childAgent] or 0) then item.childAgent = child.agent end
				end
				for _, child in shownIced do table.insert(shown, child) end
				item.family = nil
				if #shown > 0 then
					item.children = shown
					-- Folding never hides where you are.
					item.folded = folded[item.path] == true and not item.activeChild
				end
				if not item.iced then
					table.insert(row.worktrees, item)
				elseif showIcebox or item.active or item.activeChild then
					-- The active worktree stays visible even while the Ice Box is hidden.
					table.insert(iced, item)
				else
					row.hiddenIced += 1 + #shown
				end
			end
		end
		-- Ice Box worktrees sink to the bottom, keeping their relative order.
		for _, item in iced do table.insert(row.worktrees, item) end
		-- A creation Worktrunk hasn't listed yet gets its row right away, after
		-- the primary checkout.
		local pendingRows = {}
		for branch, state in (creating[project.id] or {}) do
			if not state.listed then
				table.insert(pendingRows, {
					path = "creating:" .. branch, branch = branch, creating = state, tabs = {},
					displayName = if state.label ~= branch then state.label else nil,
				})
			end
		end
		table.sort(pendingRows, function(a, b) return a.branch < b.branch end)
		local at = if row.worktrees[1] and row.worktrees[1].is_main then 2 else 1
		for index, pending in pendingRows do table.insert(row.worktrees, at + index - 1, pending) end
		-- Sessions of worktrees removed outside Overseer stay flagged until closed.
		local gonePaths = {}
		for path in (entry and entry.gone or {}) do table.insert(gonePaths, path) end
		table.sort(gonePaths)
		for _, path in gonePaths do
			local session = boundSession(path, sessions, bindings)
			if session then
				if session.id == current.id then result.activePath = path end
				local prefix = project.name .. " / "
				local name = tostring(session.name or path)
				table.insert(row.worktrees, {
					path = path, gone = true, session = session,
					label = if string.sub(name, 1, #prefix) == prefix then string.sub(name, #prefix + 1) else name,
					tabs = tabs[tostring(session.id)] or {}, agent = activity.sessions[tostring(session.id)],
				})
			end
		end
		table.insert(result.projects, row)
	end
	return result
end

local NAVIGATOR = {
	title = "Projects", about = "Local repositories, Worktrunk worktrees, and dedicated sessions.",
}

-- Overseer also owns PR outline canvases; only navigators show Projects.
local function isNavigator(canvas)
	return canvas.owner == "overseer" and canvas.title == NAVIGATOR.title
end

-- The window's one Projects slot: the navigator canvas, or a form shown in its
-- place. Adopts what a reload (or an older, per-session version) left open and
-- closes any extra, so a window never shows two.
local slotPane = nil
local function slot(cx)
	if slotPane and not cx.session:pane(slotPane) then slotPane = nil end
	local found = {}
	for _, pane in cx.session:panes() do
		if pane.block == "overseer.form" then table.insert(found, pane.pane) end
	end
	for _, canvas in cx.canvas:list() do
		if isNavigator(canvas) and cx.session:pane(canvas.pane) then table.insert(found, canvas.pane) end
	end
	slotPane = slotPane or found[1]
	for _, pane in found do
		if pane ~= slotPane then
			cx.layout:close(pane)
			rendered[pane] = nil
		end
	end
	if not slotPane then return nil end
	local info = cx.session:pane(slotPane)
	return slotPane, if info and info.block == "overseer.form" then "form" else "canvas"
end

-- Slow draws trip Tern's budget and pause every timer (see budget.luau), so
-- one that comes close says where its time went, at most once a minute.
local SLOW_DRAW_MS = 35
local slowDrawLogged = -60000

local function draw(cx)
	local started = tern.now()
	local pane, kind = slot(cx)
	if not pane or kind ~= "canvas" then return end
	-- A just-opened canvas only accepts updates once canvas:list() reports it.
	local ready = false
	for _, canvas in cx.canvas:list() do
		if canvas.pane == pane then ready = true end
	end
	if not ready then return end
	local modelStart = tern.now()
	local data = model(cx)
	local encodeStart = tern.now()
	local signature = tern.json.encode(data)
	local renderStart, setStart = tern.now(), nil
	if rendered[pane] ~= signature then
		local tree = view.render(data)
		setStart = tern.now()
		cx.canvas:set(pane, { view = tree })
		rendered[pane] = signature
	end
	local finished = tern.now()
	if finished - started >= SLOW_DRAW_MS and finished - slowDrawLogged >= 60000 then
		slowDrawLogged = finished
		tern.log.warn(string.format(
			"Overseer: slow draw %.0f ms (slot %.0f, model %.0f, encode %.0f, render %.0f, canvas %.0f; %d bytes)",
			finished - started, modelStart - started, encodeStart - modelStart, renderStart - encodeStart,
			if setStart then setStart - renderStart else 0, if setStart then finished - setStart else 0, #signature))
	end
end

-- Runs fn(cx) in a timer callback of its own, reporting (not raising) errors.
-- Tern cuts a callback short past its 50 ms budget and pauses that hook (see
-- budget.luau), so hooks other than timers only queue work here, and no
-- single callback carries a whole sequence.
local function separately(label, fn)
	budget.later(label, 0, function(cx)
		if not cx then return end
		local ok, err = pcall(fn, cx)
		if not ok and problem ~= tostring(err) then report(cx, err) end
	end)
end

-- Asks for a draw soon, in a callback of its own; requests made before the
-- draw runs share it.
local drawQueued = false
local function redraw(_cx)
	if drawQueued then return end
	drawQueued = true
	budget.later("draw", 0, function(cx)
		drawQueued = false
		if not cx then return end
		local ok, err = pcall(draw, cx)
		if not ok and problem ~= tostring(err) then report(cx, err) end
	end)
end

local PR_REFRESH_MS = 120000

-- Pull request badges are best-effort: without gh, GitHub access, or a GitHub
-- origin they simply don't appear. Stale results stay visible until a lookup
-- succeeds again.
local function refreshPullRequests(project, entry)
	local branches = {}
	for _, tree in entry.worktrees do
		if tree.branch and not tree.is_main then table.insert(branches, tree.branch) end
	end
	table.sort(branches)
	local key = table.concat(branches, "\0")
	if entry.prLoading then return end
	if key == entry.prKey and entry.prAt and tern.now() - entry.prAt < PR_REFRESH_MS then return end
	entry.prLoading = true
	wt.pull_requests(project, branches, function(found, err, cx)
		entry.prLoading, entry.prAt = false, tern.now()
		if found then
			entry.prs, entry.prKey, entry.prError = found, key, nil
		elseif err ~= entry.prError then
			entry.prError = err
			tern.log.warn("Pull requests unavailable for " .. project.name .. ": " .. tostring(err))
		end
		if cx then redraw(cx) end
		if found and cx then railsAfterPullRequests(cx, project, entry) end
	end)
end

-- Sub-worktree links (`overseer-parent`), overseer sessions (`overseer-lead`)
-- and whether agent coordination is on, read beside each listing. A failed
-- read keeps the last values, so rows don't jump out of their parents.
local function refreshLinks(project, entry)
	if entry.linksLoading then return end
	entry.linksLoading = true
	wt.links(project, function(found, err, cx)
		if found then
			entry.parents, entry.leads, entry.linksError = found.parents, found.leads, nil
		elseif err ~= entry.linksError then
			entry.linksError = err
			tern.log.warn("Sub-worktree links unavailable for " .. project.name .. ": " .. tostring(err))
		end
		wt.coordination(project, function(on, switchErr, nextCx)
			entry.linksLoading = false
			if on ~= nil then
				entry.coordination = on
			else
				tern.log.warn("Overseer: couldn't read agent coordination for " .. project.name .. ": " .. tostring(switchErr))
			end
			if nextCx then
				redraw(nextCx)
				if on ~= nil then railsAfterSwitch(nextCx, project, entry) end
				if found then railsAfterLinks(nextCx, project, entry) end
			end
		end)
	end)
end

local function inferLinear()
	if linearDefault ~= nil then return end
	linearDefault = false
	wt.linear_workspace(function(slug, err, cx)
		if slug then
			linearDefault = slug
			if cx then redraw(cx) end
		else
			tern.log.info("Linear ticket links need a workspace: " .. tostring(err))
		end
	end)
end

-- Worktrees removed outside Overseer (an agent's `wt merge`, `wt remove` in a
-- shell) leave their records behind. After a listing succeeds, a recorded path
-- that is neither listed nor on disk is gone: its display name and Ice Box
-- entry are dropped, and so is its session binding unless that session is
-- still open, in which case the panel flags it (`entry.gone`) for you to close.
local function reconcileGone(cx, project, entry)
	local listed = {}
	for _, worktree in entry.worktrees do listed[worktree.path] = true end
	local jobs = records("jobs")
	local function gone(path)
		return not listed[path] and not removing(path, jobs) and not tern.fs.exists(path)
	end
	local before = entry.gone or {}
	entry.gone = {}
	local sessions = sessionsById(cx)
	local bindings, unbound = records("sessions"), false
	for path, binding in bindings do
		if binding.project == project.id and gone(path) then
			if boundSession(path, sessions, bindings) then
				entry.gone[path] = true
				if not before[path] then
					oplog.write("info", { op = "worktree", event = "gone", project = project.name, path = path,
						detail = "removed outside Overseer; its session is still open" })
				end
			else
				bindings[path] = nil
				unbound = true
				oplog.write("info", { op = "worktree", event = "gone", project = project.name, path = path,
					detail = "removed outside Overseer; dropped its session record" })
			end
		end
	end
	if unbound then tern.kv.set("sessions", bindings) end
	for _, key in { "worktree-names", "icebox" } do
		local store = records(key)
		local paths, dropped = store[project.id], false
		for path in (paths or {}) do
			if gone(path) then
				paths[path] = nil
				dropped = true
			end
		end
		if dropped then tern.kv.set(key, store) end
	end
	-- Rails records of gone worktrees (queues drain themselves in flushRails).
	local rails, pruned = railsState(), false
	for _, key in { "told", "checkin", "unread" } do
		for path in rails[key] do
			if gone(path) then
				rails[key][path], pruned = nil, true
			end
		end
	end
	if pruned then tern.kv.set("rails", rails) end
end

-- `done` runs once every worktree listing this call started has finished.
local function refresh(cx, done)
	lastRefresh = tern.now()
	inferLinear()
	local pending = 0
	for _, project in projects() do
		local entry = cache[project.id]
		if not entry then
			entry = { worktrees = {} }
			cache[project.id] = entry
		end
		if not entry.loading then
			entry.loading = true
			pending += 1
			refreshLinks(project, entry)
			wt.list(project, function(worktrees, err, nextCx)
				entry.loading, entry.error = false, err
				local previous = {}
				for _, tree in entry.worktrees do previous[tree.path] = tree.head end
				if worktrees then entry.worktrees = worktrees end
				if worktrees and nextCx then
					reconcileGone(nextCx, project, entry)
					railsAfterListing(nextCx, project, entry, previous)
				end
				pending -= 1
				if pending == 0 and done and nextCx then done(nextCx) end
				if nextCx then redraw(nextCx) end
				if worktrees then refreshPullRequests(project, entry) end
			end)
		end
	end
	if pending == 0 and done then done(cx) end
	redraw(cx)
end

-- ↻ spins from an explicit refresh until its worktree listings finish, and
-- for at least one turn so a fast refresh is still visible.
local SPIN_MIN_MS = 800

local function refreshByHand(cx)
	if spinning then return end
	spinning = true
	local started = tern.now()
	-- An explicit refresh also re-checks pull requests immediately.
	for _, entry in cache do entry.prAt = nil end
	if linearDefault == false then linearDefault = nil end
	refresh(cx, function(doneCx)
		local function stop(stopCx)
			spinning = false
			if stopCx then redraw(stopCx) end
		end
		local left = started + SPIN_MIN_MS - tern.now()
		if left > 0 then budget.later("refresh spinner", left, stop) else stop(doneCx) end
	end)
end

-- Tern panes belong to one tab, so the window's one Projects panel follows you:
-- whenever another tab is shown, it moves there, full height on the left.
local DEFAULT_SHARE = 0.3
-- The width you leave it at travels with it (a share of the tab).
local share = tonumber(tern.kv.get("panel-share")) or DEFAULT_SHARE
-- Whether you want the panel shown; it reopens after vanishing with its tab.
local wantPanel = tern.kv.get("panel-open") == true
-- The tab the panel was last placed in, to tell a closed panel from a closed tab.
local panelTab = nil

local function firstLeaf(tree, skip)
	if not tree then return nil end
	if tree.pane then return if tree.pane == skip then nil else tree.pane end
	return firstLeaf(tree[1], skip) or firstLeaf(tree[2], skip)
end

-- Whether `tree` contains `pane`.
local function hasPane(tree, pane)
	if not tree then return false end
	if tree.pane then return tree.pane == pane end
	return hasPane(tree[1], pane) or hasPane(tree[2], pane)
end

-- The panel's share of the tab's width while it is the leftmost pane, however
-- deeply the tab's splits nest it. Each "right" split it sits left of multiplies
-- the share; "down" splits don't change its width. A pane that isn't on the left
-- edge returns nil, so pin still moves it there.
local function leftShare(cx, tab, pane)
	local layout = cx.session:layout(tab)
	local node = layout and layout.root
	local share = 1
	while node and not node.pane do
		if node.split == "right" then
			if not hasPane(node[1], pane) then return nil end
			share = share * node.ratio
			node = node[1]
		elseif hasPane(node[1], pane) then
			node = node[1]
		else
			node = node[2]
		end
	end
	if node and node.pane == pane then return share end
	return nil
end

-- Tern resizes in cells, and a hidden tab's cells differ from the shown one's,
-- so steer by the ratio: step, see how far it moved, correct.
local function sizeTo(cx, tab, pane, want)
	local r = leftShare(cx, tab, pane)
	local step = if r then math.floor((want - r) * 180 + 0.5) else 0
	for _ = 1, 8 do
		if not r or math.abs(r - want) < 0.005 or step == 0 then return end
		cx.layout:resize(pane, "right", step)
		local after = leftShare(cx, tab, pane)
		if not after or after == r then return end
		step = math.floor((want - after) * step / (after - r) + 0.5)
		r = after
	end
end

-- Moves the slot into `tab`, left of everything, unless it is already there.
local function pin(cx, tab)
	local pane = slot(cx)
	if not pane then return end
	local layout = cx.session:layout(tab)
	if not layout then return end
	local from = cx.session:tab_of(pane)
	if from == tab and firstLeaf(layout.root) == pane then
		panelTab = tab
		return
	end
	local target = firstLeaf(layout.root, pane)
	if not target then return end
	if from then
		local current = leftShare(cx, from, pane)
		if current and math.abs(current - share) > 0.01 then
			share = math.clamp(current, 0.15, 0.6)
			tern.kv.set("panel-share", share)
		end
	end
	if from ~= tab then
		if from then
			cx.layout:move_to_tab(pane, tab, { focus = false })
		else
			cx.layout:unpark(pane, { focus = false })
		end
	end
	cx.layout:move(pane, target, "left", { focus = false })
	sizeTo(cx, tab, pane, share)
	panelTab = tab
end

local function shownTab(cx)
	local focused = cx.session:focused()
	return focused and cx.session:tab_of(focused)
end

-- The Settings block (settings.luau) opens in a tab of its own, which the
-- panel leaves alone: Settings gets the whole tab.
local SETTINGS_BLOCK = "overseer.settings"
local function settingsPane(cx)
	for _, pane in cx.session:panes() do
		if pane.block == SETTINGS_BLOCK then return pane end
	end
	return nil
end

local function settingsTab(cx, tab)
	local pane = settingsPane(cx)
	return pane ~= nil and pane.tab == tab
end

-- A toast with a button (Tern 0.9.14). Only a toast node drawn in a view can
-- carry one, so it goes through the Projects panel; with the panel hidden or
-- a form in its place, it is a plain toast and `hint` takes the button's
-- place in `sub`. `button` is { label, action, hint? }; its click arrives as
-- an ordinary canvas action.
local noticeCount = 0
local function notify(cx, level, text, sub, button)
	local pane, kind = slot(cx)
	local shown = pane ~= nil and kind == "canvas" and cx.session:tab_of(pane) == shownTab(cx)
	if not button or not shown then
		local hint = button and button.hint
		cx:toast(level, text, if hint then (if sub then sub .. ". " .. hint else hint) else sub)
		return
	end
	noticeCount += 1
	notice = {
		n = noticeCount, at = os.time(), text = text, sub = sub, tone = level,
		action = button.action, label = button.label,
	}
	redraw(cx)
end

-- Forgets finished-agent marks you have now seen (their tab is shown) or that
-- can't be seen any more (their pane closed).
local function markSeen(cx)
	local finished = finishedAgents()
	if next(finished) == nil then return end
	local tab = shownTab(cx)
	local changed = false
	for key in finished do
		local info = cx.session:pane(tonumber(key))
		if not info or (tab and info.tab == tab) then
			finished[key] = nil
			changed = true
		end
	end
	if changed then tern.kv.set("agents-finished", finished) end
end

local function setWantPanel(want)
	wantPanel = want
	tern.kv.set("panel-open", want)
end

-- Opens a fresh navigator in `tab`.
local function openPanel(cx, tab)
	local data = model(cx)
	local pane, err = cx.canvas:open({
		title = NAVIGATOR.title, about = NAVIGATOR.about,
		view = view.render(data), how = "beside", focus = false,
	})
	if not pane then report(cx, err or "Could not open the Projects panel"); return nil end
	slotPane = pane
	rendered[pane] = tern.json.encode(data)
	if tab then pin(cx, tab) end
	return pane
end

-- Keeps the panel in the shown tab. Runs on every tab, pane and focus event and
-- each tick, so one disabled hook can't leave it behind.
local function follow(cx, tab)
	if not localHost(cx) then return end
	tab = tab or shownTab(cx)
	if not tab then return end
	if settingsTab(cx, tab) then return end
	local pane = slot(cx)
	if not pane then
		if not wantPanel then return end
		-- Gone while its tab remains: you closed it. Gone with its tab (a closed
		-- session or tab): bring it back here.
		local tabStillOpen = false
		for _, info in cx.session:tabs() do
			if info.id == panelTab then tabStillOpen = true end
		end
		if tabStillOpen then
			setWantPanel(false)
			panelTab = nil
			return
		end
		openPanel(cx, tab)
		return
	end
	-- Alone in the shown tab: its last terminal just closed. Close the tab as
	-- Tern would have; the tab shown next takes the panel.
	local layout = cx.session:tab_of(pane) == tab and cx.session:layout(tab)
	if layout and not firstLeaf(layout.root, pane) then
		cx.layout:park(pane)
		return
	end
	-- A panel already open (for example, from before an update) is one you want.
	if not wantPanel then setWantPanel(true) end
	pin(cx, tab)
end

-- Swaps `slot` for a new pane in the same place and size: Tern has no in-place
-- replace for canvases, so open the new pane beside the old one (splitting only
-- that slot), then close the old one so the new pane inherits the whole slot.
local function swapSlot(cx, old, open)
	cx.layout:focus(old)
	local pane, err = open()
	if not pane then return nil, err end
	cx.layout:close(old)
	rendered[old] = nil
	slotPane = pane
	return pane
end

-- Shows the Projects panel in the shown tab and focuses it, opening it if needed.
local function navigator(cx)
	if not requireLocal(cx) then return nil end
	setWantPanel(true)
	local tab = shownTab(cx)
	local pane = slot(cx)
	if pane then
		if tab then pin(cx, tab) end
	else
		pane = openPanel(cx, tab)
		if not pane then return nil end
	end
	cx.layout:focus(pane)
	refresh(cx)
	return pane
end

-- The Projects shortcut: hides the panel when it has focus, otherwise shows and focuses it.
local function togglePanel(cx)
	if not requireLocal(cx) then return end
	local pane, kind = slot(cx)
	if pane and kind == "canvas" and cx.session:focused() == pane then
		setWantPanel(false)
		cx.layout:close(pane)
		rendered[pane] = nil
		slotPane, panelTab = nil, nil
		return
	end
	navigator(cx)
end

local function findWorktree(path)
	for _, project in projects() do
		local entry = cache[project.id]
		for _, worktree in (entry and entry.worktrees or {}) do
			if worktree.path == path then return project, worktree end
		end
	end
	return nil, nil
end

-- Shows the worktree's session, creating and binding one when it has none.
-- The panel follows into it (see follow).
local function ensureSession(cx, project, path, branch)
	local session = boundSession(path, sessionsById(cx))
	if session then
		cx.sessions:switch(session.id)
	else
		session = cx.sessions:create({ name = project.name .. " / " .. (branch or "detached"), cwd = path })
		local bindings = records("sessions")
		bindings[path] = { id = session.id, host = session.host, project = project.id }
		tern.kv.set("sessions", bindings)
	end
	follow(cx)
end

-- Coordination rails, the relays: what happens in a sub-worktree's session
-- reaches its parent's overseer session, and a parent branch moving reaches
-- the sub-worktrees built on it. Decisions come from Tern's agent states and
-- git, never from what an agent wrote; quoted text is only passed along.

-- A session gets at most one message a minute; what comes sooner waits in its
-- queue and goes out together. Messages you send from Projects skip the wait.
local RAILS_RATE_S = 60
local RAILS_QUEUE_MAX = 8
local RAILS_ATTEMPTS = 3
-- A finished turn is relayed once its pull request is known, if that's within this long.
local RAILS_PR_WAIT_S = 15 * 60

local function paneKey(pane)
	return string.format("%d", pane)
end

local function oneLine(text, limit)
	local flat = string.gsub(string.gsub(text or "", "%s+", " "), "^ ", "")
	local cut = utf8.offset(flat, limit)
	return if cut and cut <= #flat then string.sub(flat, 1, cut - 1) .. "…" else flat
end

local function treeLabel(project, worktree)
	local name = (records("worktree-names")[project.id] or {})[worktree.path]
	local branch = worktree.branch or "detached HEAD"
	return if name then branch .. " (" .. name .. ")" else branch
end

-- Whether a worktree takes part in a family: a parent link, or sub-worktrees.
local function inFamily(entry, worktree)
	local branch = worktree.branch
	if not branch or not entry.parents then return false end
	if entry.parents[branch] then return true end
	for _, parent in entry.parents do
		if parent == branch then return true end
	end
	return false
end

local function ownerTree(entry, worktree)
	local ownerPath = owners(entry)[worktree.path]
	for _, tree in (ownerPath and entry.worktrees or {}) do
		if tree.path == ownerPath then return tree end
	end
	return nil
end

-- Whether agent coordination is on for a project's repository. Unknown (not
-- read yet) counts as off.
local function coordinating(project)
	local entry = project and cache[project.id]
	return entry ~= nil and entry.coordination == true
end

-- Sends what waits in the queues to the worktrees' overseer sessions. Tern
-- hands each message to the agent as a prompt, queued until it can take one.
local function flushRails(cx)
	local rails = railsState()
	local changed, delivered = false, false
	-- Rate-limit marks only matter for RAILS_RATE_S; panes come and go.
	for pane, at in rails.sentAt do
		if type(at) ~= "number" or os.time() - at >= RAILS_RATE_S then rails.sentAt[pane], changed = nil, true end
	end
	if next(rails.queue) == nil then
		if changed then tern.kv.set("rails", rails) end
		return
	end
	local agents = worktreeAgents(cx)
	for path, queue in rails.queue do
		local project, worktree = findWorktree(path)
		local pane = project and leadOf(cache[project.id], worktree, agents)
		local now = false
		for _, item in queue do now = now or item.now == true end
		if not project and not tern.fs.exists(path) then
			rails.queue[path], changed = nil, true
		elseif project and cache[project.id].coordination == false then
			-- Coordination was turned off: what was waiting goes too.
			rails.queue[path], changed = nil, true
		elseif pane and (now or os.time() - (rails.sentAt[paneKey(pane)] or 0) >= RAILS_RATE_S) then
			rails.queue[path], changed = nil, true
			rails.sentAt[paneKey(pane)] = os.time()
			local texts, attempts = {}, 0
			for _, item in queue do
				table.insert(texts, item.text)
				attempts = math.max(attempts, item.attempts or 0)
			end
			local text = if #texts == 1 then texts[1] else "Overseer: " .. #texts .. " updates.\n\n" .. table.concat(texts, "\n\n")
			local ok, err = pcall(function() cx.agents:ask(pane, text) end)
			if ok then
				rails.unread[path] = (rails.unread[path] or 0) + 1
				delivered = true
				oplog.write("info", { op = "relay", event = "delivered", path = path,
					detail = tostring(#texts) .. " message" .. (if #texts == 1 then "" else "s") })
			else
				oplog.write("warn", { op = "relay", event = "failed", path = path,
					detail = tostring(err) .. (if attempts + 1 < RAILS_ATTEMPTS then "; will retry" else "; gave up") })
				if attempts + 1 < RAILS_ATTEMPTS then
					for _, item in queue do item.attempts = attempts + 1 end
					rails.queue[path] = queue
				end
			end
		end
	end
	if changed then tern.kv.set("rails", rails) end
	if delivered then redraw(cx) end
end

-- Queues `text` for the overseer session of the worktree at `path`; it goes
-- out once the worktree has one and the rate limit allows (`now` skips the wait).
-- Nothing is queued for a repository with coordination off.
local function tell(cx, path, text, now)
	local project = findWorktree(path)
	if project and not coordinating(project) then return end
	local rails = railsState()
	local queue = rails.queue[path] or {}
	table.insert(queue, { text = text, at = os.time(), now = now or nil })
	while #queue > RAILS_QUEUE_MAX do table.remove(queue, 1) end
	rails.queue[path] = queue
	tern.kv.set("rails", rails)
	flushRails(cx)
end

-- Keeps `overseer-lead` true for worktrees in a family: a lead whose agent
-- stopped is cleared, and a worktree with one running agent gets it as lead.
-- With several and no lead, you pick one (Make overseer session).
local function syncLeads(cx, project, entry)
	if entry.coordination ~= true or not entry.leads or not entry.worktrees then return end
	local agents = worktreeAgents(cx)
	entry.leadWrites = entry.leadWrites or {}
	for _, worktree in entry.worktrees do
		local branch = worktree.branch
		if branch and not entry.leadWrites[branch] and inFamily(entry, worktree) then
			local pane = leadOf(entry, worktree, agents)
			local value = if pane then paneKey(pane) else nil
			if value ~= entry.leads[branch] then
				entry.leads[branch] = value
				entry.leadWrites[branch] = true
				wt.set_var(project, branch, wt.LEAD_KEY, value, function(ok, err, nextCx)
					entry.leadWrites[branch] = nil
					if not ok then tern.log.warn("Overseer: couldn't save the overseer session of " .. branch .. ": " .. tostring(err)) end
					if nextCx then
						flushRails(nextCx)
						redraw(nextCx)
					end
				end)
			end
		end
	end
end

local function syncAllLeads(cx)
	for _, project in projects() do
		local entry = cache[project.id]
		if entry then syncLeads(cx, project, entry) end
	end
	flushRails(cx)
end

-- Relays finished turns of sub-worktrees whose pull request is known: once per
-- PR and head commit, and only for turns that ended since Overseer has watched.
local function noticeFinished(cx, project, entry)
	local rails, changed = railsState(), false
	for _, worktree in (entry.worktrees or {}) do
		local told = rails.told[worktree.path]
		local pr = worktree.branch and entry.prs and entry.prs[worktree.branch]
		if told and told.finishedAt then
			local owner = ownerTree(entry, worktree)
			local key = pr and tostring(pr.number) .. "@" .. (worktree.head or "")
			if not owner or os.time() - told.finishedAt > RAILS_PR_WAIT_S then
				told.finishedAt, changed = nil, true
			elseif pr and told.pr ~= key then
				told.pr, told.finishedAt, changed = key, nil, true
				local said = oneLine(told.lastMessage, 300)
				tell(cx, owner.path, string.format(
					"Overseer: sub-worktree %s finished a turn with PR #%s (%s): %s. Its last message: \"%s\"",
					treeLabel(project, worktree), tostring(pr.number), tostring(pr.state), tostring(pr.url or ""), said))
			end
		end
	end
	if changed then
		-- tell() rewrote the store; merge what this pass changed into the latest.
		local latest = railsState()
		for path, told in rails.told do latest.told[path] = told end
		tern.kv.set("rails", latest)
	end
end

-- An agent's state changed: record check-ins, and relay a sub-worktree's
-- overseer session waiting, failing or finishing to its parent.
local function onAgentChange(cx, pane, kind)
	local agents = worktreeAgents(cx)
	local project, entry, worktree = nil, nil, nil
	for path, list in agents do
		for _, candidate in list do
			if candidate.pane == pane then
				project, worktree = findWorktree(path)
				entry = project and cache[project.id]
			end
		end
	end
	if not project or not coordinating(project) then return end
	local rails = railsState()
	local told = rails.told[worktree.path] or {}
	if kind == "working" then
		-- A new turn: a later wait or failure is news again.
		told.waiting, told.failed = nil, nil
	elseif kind ~= "waiting" then
		rails.checkin[worktree.path] = os.time()
	end
	local owner = leadOf(entry, worktree, agents) == pane and ownerTree(entry, worktree)
	local text = nil
	-- Only the full agent list has its last reply; this runs once per state change.
	local said = ""
	for _, listed in cx.agents:list() do
		if listed.pane == pane then said = oneLine(listed.last_message, 300) end
	end
	local quoted = if said ~= "" then " Its last message: \"" .. said .. "\"" else ""
	if owner and kind == "waiting" and not told.waiting then
		told.waiting = true
		text = string.format(
			"Overseer: sub-worktree %s is waiting for an answer.%s\nAnswer with the overseer_family tool (action \"message\", to \"%s\").",
			treeLabel(project, worktree), quoted, worktree.branch)
	elseif owner and kind == "failed" and not told.failed then
		told.failed = true
		text = string.format("Overseer: sub-worktree %s's turn failed.%s", treeLabel(project, worktree), quoted)
	elseif owner and kind == "done" then
		told.finishedAt, told.lastMessage = os.time(), said
	end
	rails.told[worktree.path] = told
	tern.kv.set("rails", rails)
	if text then tell(cx, owner.path, text) end
	if kind == "done" then noticeFinished(cx, project, entry) end
	redraw(cx)
end

-- A parent branch moved: sub-worktrees built on its earlier commits hear about it.
local function noticeMoves(project, entry, previous)
	local ownerOf = owners(entry)
	for _, parent in entry.worktrees do
		local old = previous[parent.path]
		if old and parent.head and old ~= parent.head and parent.branch then
			for _, child in entry.worktrees do
				if ownerOf[child.path] == parent.path and child.branch then
					-- Built on it: the child has the parent's old tip, and that tip isn't on the base branch.
					wt.is_ancestor(project, old, child.branch, function(inChild)
						if not inChild then return end
						wt.is_ancestor(project, old, project.base, function(onBase)
							if onBase ~= false then return end
							wt.new_commits(project, old, parent.head, 5, function(lines, count, cx)
								if not cx then return end
								tell(cx, child.path, string.format(
									"Overseer: your parent %s moved: %s (%s). %s is built on it, so it may need rebasing onto %s.",
									parent.branch, if count == 0 then "history rewritten" else tostring(count) .. " new commit" .. (if count == 1 then "" else "s"),
									table.concat(lines, "; "), child.branch, parent.branch))
							end)
						end)
					end)
				end
			end
		end
	end
end

-- Briefs: overseer-subworktree --brief leaves the sub-task's first prompt as
-- overseer-brief.md in the new worktree's private git dir.
local function briefFile(path)
	local ok, text = pcall(tern.fs.read, path .. "/.git", 4096)
	local gitdir = ok and type(text) == "string" and string.match(text, "^gitdir:%s*(.-)%s*$")
	if not gitdir then return nil end
	if string.sub(gitdir, 1, 1) ~= "/" then gitdir = path .. "/" .. gitdir end
	return gitdir .. "/overseer-brief.md"
end

-- Starts an omp session on a brief: in the worktree's session when it has one,
-- else a new bound session, without taking you away from what you're looking at.
local function startBrief(cx, project, worktree, file)
	local okRead, brief = pcall(tern.fs.read, file, 65536)
	if not okRead or type(brief) ~= "string" then return end
	local started = string.gsub(file, "%.md$", ".started.md")
	-- Tern runs the command through your shell; keep the path a single plain word.
	if string.find(started, "[^%w%._/%-]") then
		report(cx, "Its git directory path has characters a shell would split: " .. started, "Brief not started")
		return
	end
	-- Move it first, so the next refresh can't start it twice.
	local reportBack = if coordinating(project) then ": report back with the overseer_family tool (to: parent).\n" else ".\n"
	tern.fs.write(started, brief .. "\n\n---\nOverseer started this session from the brief your parent worktree left. "
		.. "This worktree (" .. worktree.branch .. ") is its sub-worktree" .. reportBack)
	tern.fs.remove(file)
	local ternBin = wt.find_executable("tern") or "/Applications/Tern.app/Contents/MacOS/tern"
	local session = boundSession(worktree.path, sessionsById(cx))
	local argv = { ternBin, "new" }
	if session then
		for _, arg in { "tab", string.format("%d", session.id) } do table.insert(argv, arg) end
	else
		for _, arg in { "session", project.name .. " / " .. worktree.branch } do table.insert(argv, arg) end
	end
	for _, arg in { "--window", cx:window_key(), "--json", "--cwd", worktree.path, "--", "omp", "@" .. started } do
		table.insert(argv, arg)
	end
	local ok, err = pcall(budget.process, "brief start", argv, { timeout_ms = 15000 }, function(result, nextCx)
		local parsed, value = pcall(tern.json.decode, result.stdout or "")
		if result.status ~= 0 or not parsed or type(value) ~= "table" then
			-- Put the brief back for the next refresh to try again.
			tern.fs.write(file, brief)
			tern.fs.remove(started)
			if nextCx then report(nextCx, tostring(result.stderr or "tern new failed"), "Brief not started") end
			oplog.write("warn", { op = "brief", event = "failed", project = project.name, branch = worktree.branch,
				detail = tostring(result.stderr or "tern new failed") })
			return
		end
		if not session and value.session and nextCx then
			local bindings = records("sessions")
			local host = nil
			for _, listed in nextCx.sessions:list() do
				if listed.id == value.session then host = listed.host end
			end
			bindings[worktree.path] = { id = value.session, host = host, project = project.id }
			tern.kv.set("sessions", bindings)
		end
		oplog.write("info", { op = "brief", event = "started", project = project.name, branch = worktree.branch })
		if nextCx then
			nextCx:toast("info", "Sub-worktree started", treeLabel(project, worktree) .. " is working on its brief.")
			redraw(nextCx)
		end
	end)
	if not ok then
		tern.fs.write(file, brief)
		tern.fs.remove(started)
		report(cx, tostring(err), "Brief not started")
	end
end

local function startBriefs(cx, project, entry)
	for _, worktree in entry.worktrees do
		if worktree.branch and not worktree.is_main then
			local file = briefFile(worktree.path)
			if file and tern.fs.exists(file) then startBrief(cx, project, worktree, file) end
		end
	end
end

-- Makes the agent in tab `tabId` the overseer session of the worktree at `path`.
local function makeLead(cx, path, tabId)
	local project, worktree = findWorktree(path)
	if not project or not worktree.branch then report(cx, "Worktree not found. Refresh Projects."); return end
	if not coordinating(project) then report(cx, "Turn on agent coordination for this repository first.", "Agent coordination is off"); return end
	local pane = nil
	for _, agent in (worktreeAgents(cx)[path] or {}) do
		local info = cx.session:pane(agent.pane)
		if info and info.tab == tabId then pane = agent.pane end
	end
	if not pane then report(cx, "That tab has no running agent."); return end
	local entry = cache[project.id]
	entry.leads = entry.leads or {}
	entry.leads[worktree.branch] = paneKey(pane)
	redraw(cx)
	wt.set_var(project, worktree.branch, wt.LEAD_KEY, paneKey(pane), function(ok, err, nextCx)
		if not ok and nextCx then report(nextCx, err, "Couldn't save the overseer session") end
		if nextCx then flushRails(nextCx) end
	end)
end

-- Sends your message from the Brief sub-worktrees form to every sub-worktree of `path`.
local function briefChildren(cx, path, message)
	local project, worktree = findWorktree(path)
	if not project then return nil, "Worktree is no longer available. Refresh Projects." end
	if not coordinating(project) then return nil, "Agent coordination is off for this repository. Turn it on from the project's menu." end
	local entry = cache[project.id]
	local ownerOf, sent = owners(entry), 0
	for _, tree in entry.worktrees do
		if ownerOf[tree.path] == path then
			tell(cx, tree.path, "Overseer, passing on a message from the user to every sub-worktree of "
				.. (worktree.branch or path) .. ":\n\n" .. message, true)
			sent += 1
		end
	end
	if sent == 0 then return nil, "This worktree has no sub-worktrees." end
	return sent
end

-- Messages agents leave for their relatives (the overseer_family tool): one
-- JSON file per message in <repository git dir>/overseer/outbox/, delivered
-- to the recipient worktree's overseer session and then removed. Only for
-- repositories with coordination on; until it's on, files stay put.
local MAIL_MAX_BYTES = 16384

local function deliverMail(cx)
	for _, project in projects() do
		local entry = cache[project.id]
		if coordinating(project) and entry.worktrees and #entry.worktrees > 0 then
			local dir = project.id .. "/overseer/outbox"
			local listed, names = pcall(tern.fs.list, dir)
			for _, name in (if listed then names else {}) do
				if string.sub(name, -5) == ".json" then
					local file = dir .. "/" .. name
					local read, text = pcall(tern.fs.read, file, MAIL_MAX_BYTES)
					local decoded, mail = false, nil
					if read then decoded, mail = pcall(tern.json.decode, text) end
					local valid = decoded and type(mail) == "table" and type(mail.to) == "string"
						and type(mail.text) == "string" and string.find(mail.text, "%S") ~= nil
						and type(mail.from) == "table" and type(mail.from.branch) == "string"
					if not valid then
						oplog.write("warn", { op = "message", event = "unreadable", project = project.name, detail = name })
					else
						local ownerOf, target, sender = owners(entry), nil, nil
						for _, tree in entry.worktrees do
							if tree.branch == mail.to then target = tree end
							if tree.branch == mail.from.branch then sender = tree end
						end
						if target then
							local relation = if sender and ownerOf[target.path] == sender.path then "parent"
								elseif sender and ownerOf[sender.path] == target.path then "sub-worktree"
								else "relative"
							oplog.write("info", { op = "message", event = "queued", project = project.name, branch = mail.to,
								detail = "from " .. mail.from.branch })
							tell(cx, target.path, string.format(
								"Overseer: message from the overseer session of %s (your %s):\n\n%s\n\n(Reply with the overseer_family tool: action \"message\", to \"%s\".)",
								mail.from.branch, relation, mail.text, mail.from.branch), true)
						else
							oplog.write("warn", { op = "message", event = "undeliverable", project = project.name, branch = mail.to,
								detail = "from " .. mail.from.branch .. ": no worktree on that branch" })
						end
					end
					pcall(tern.fs.remove, file)
				end
			end
		end
	end
end

-- 2.4.0 made coordination opt-in. Once per repository, a project that already
-- used it (an overseer session on record, or relays in Overseer's state) keeps
-- it on; every other project starts off.
function railsAfterSwitch(cx, project, entry)
	local migrated = records("coordination-migrated")
	if migrated[project.id] or entry.migrating then return end
	-- Judge only with the listing and the links in.
	if not entry.worktrees or #entry.worktrees == 0 or not entry.leads then return end
	local used = entry.coordination == true or next(entry.leads) ~= nil
	if not used then
		local rails = railsState()
		for _, worktree in entry.worktrees do
			for _, key in { "queue", "unread", "checkin", "told" } do
				if rails[key][worktree.path] ~= nil then used = true end
			end
		end
	end
	local function done()
		local latest = records("coordination-migrated")
		latest[project.id] = true
		tern.kv.set("coordination-migrated", latest)
	end
	if entry.coordination == true or not used then done(); return end
	entry.migrating = true
	wt.set_coordination(project, true, function(ok, err, nextCx)
		entry.migrating = nil
		if not ok then
			tern.log.warn("Overseer: couldn't keep agent coordination on for " .. project.name .. ": " .. tostring(err))
			return
		end
		entry.coordination = true
		done()
		oplog.write("info", { op = "coordination", event = "on", project = project.name,
			detail = "kept on: this repository used it before coordination became opt-in" })
		if nextCx then redraw(nextCx) end
	end)
end

function railsAfterListing(cx, project, entry, previous)
	noticeMoves(project, entry, previous)
	startBriefs(cx, project, entry)
	syncLeads(cx, project, entry)
	if entry.coordination ~= nil then railsAfterSwitch(cx, project, entry) end
	flushRails(cx)
end

function railsAfterLinks(cx, project, entry)
	syncLeads(cx, project, entry)
	flushRails(cx)
end

function railsAfterPullRequests(cx, project, entry)
	noticeFinished(cx, project, entry)
end

local function openWorktree(cx, path)
	if not requireLocal(cx) then return end
	if removing(path) then report(cx, "Check the Delete tab.", "Deletion in progress"); return end
	local project, worktree = findWorktree(path)
	if not project then
		-- A worktree removed outside Overseer: its flagged session can still be shown.
		local session = boundSession(path, sessionsById(cx))
		if session and not tern.fs.exists(path) then
			cx.sessions:switch(session.id)
			follow(cx)
			redraw(cx)
			return
		end
		report(cx, "Worktree not found. Refresh Projects."); return
	end
	if not tern.fs.exists(path) then report(cx, "Worktree directory is missing: " .. path, "Worktree unavailable"); refresh(cx); return end
	ensureSession(cx, project, path, worktree.branch)
	redraw(cx)
end

local function token()
	sequence += 1
	return tostring(os.time()) .. "-" .. tostring(math.floor(tern.now() * 1000)) .. "-" .. tostring(math.random(1, 1000000000)) .. "-" .. tostring(sequence)
end

local function closeGuard(cx, path)
	local session = boundSession(path, sessionsById(cx))
	if not session then return nil, nil end
	if session.locked then return nil, "Unlock the session first." end
	local tabs = {}
	for _, tab in cx.session:tabs() do tabs[tab.id] = tab.session end
	for _, job in records("jobs") do
		local tab = cx.session:tab_of(job.pane)
		if tab and tabs[tab] == session.id then
			return nil, "Finish or cancel the running operation."
		end
	end
	return session, nil
end

local function closeManagedSession(cx, path, expected)
	local bindings = records("sessions")
	local binding = bindings[path]
	if not binding then return true end
	if expected and (binding.id ~= expected.id or binding.host ~= expected.host) then return true end
	local session, err = closeGuard(cx, path)
	if err then return false, err end
	if session then
		if cx.sessions:current().id == session.id then
			-- Land in the project's primary checkout session when it's open (it also
			-- holds a deletion's output tab); otherwise any other session.
			local replacement
			local project = projectById(binding.project)
			local primary = project and bindings[project.path]
			for _, other in cx.sessions:list() do
				if other.id ~= session.id and other.host == session.host then
					if primary and other.id == primary.id then replacement = other; break end
					replacement = replacement or other
				end
			end
			if replacement then
				cx.sessions:switch(replacement.id)
			else
				cx.sessions:create({ name = "Projects", cwd = project and project.path })
			end
		end
		-- The panel lives in the shown tab: take it into the session shown now,
		-- or it closes with this one.
		follow(cx)
		cx.sessions:close(session.id)
	end
	bindings[path] = nil
	tern.kv.set("sessions", bindings)
	return true
end

-- Removing a project only stops Overseer tracking it. Display names, Ice Box
-- entries and session bindings are keyed by path, so they stay and come back
-- if the repository is added again.
local function requestProjectRemoval(cx, id)
	local project = projectById(id)
	if not project then report(cx, "Project not found. Refresh Projects."); return end
	for _, job in records("jobs") do
		if job.project == project.id then
			report(cx, "Finish the running worktree operation first.", "Project busy"); return
		end
	end
	confirmation = {
		id = token(), kind = "remove-project", path = project.path, label = project.name, project = project.id,
	}
	redraw(cx)
end

-- Projects removed this run, for the Undo on their toast: id -> { project, index }.
local removedProjects = {}

local function removeProject(cx, request)
	confirmation = nil
	local kept = {}
	for index, project in projects() do
		if project.id == request.project then
			removedProjects[project.id] = { project = project, index = index }
		else
			table.insert(kept, project)
		end
	end
	tern.kv.set("projects", kept)
	cache[request.project], collapsed[request.project] = nil, nil
	notify(cx, "info", "Project removed", notificationLabel(request.label),
		{ label = "Undo", action = "restore-project=" .. request.project })
	redraw(cx)
end

-- Undo on the Project removed toast: puts the project back where it was.
local function restoreProject(cx, id)
	local removed = removedProjects[id]
	removedProjects[id] = nil
	if not removed or projectById(id) then return end
	local all = projects()
	table.insert(all, math.min(removed.index, #all + 1), removed.project)
	tern.kv.set("projects", all)
	cx:toast("info", "Project restored", notificationLabel(removed.project.name))
	refresh(cx)
	redraw(cx)
end

-- Agent coordination, from the project's menu. Turning it on asks first.
local function setCoordination(cx, id, on)
	local project = projectById(id)
	if not project then report(cx, "Project not found. Refresh Projects."); return end
	wt.set_coordination(project, on, function(ok, err, nextCx)
		if not nextCx then return end
		if not ok then report(nextCx, err, "Couldn't change agent coordination"); return end
		local entry = cache[project.id]
		if entry then entry.coordination = on end
		-- A choice made by hand settles the opt-in migration for this repository.
		local migrated = records("coordination-migrated")
		migrated[project.id] = true
		tern.kv.set("coordination-migrated", migrated)
		oplog.write("info", { op = "coordination", event = if on then "on" else "off", project = project.name })
		nextCx:toast("info", if on then "Agent coordination on" else "Agent coordination off", notificationLabel(project.name))
		if on and entry then railsAfterLinks(nextCx, project, entry) else flushRails(nextCx) end
		redraw(nextCx)
	end)
end

local function requestCoordination(cx, id)
	local project = projectById(id)
	if not project then report(cx, "Project not found. Refresh Projects."); return end
	confirmation = { id = token(), kind = "coordination-on", path = project.path, label = project.name, project = project.id }
	redraw(cx)
end

-- Open PR outline canvases by "<project id>#<number>": asking again focuses the open one.
local outlines = {}

local function setOutline(cx, pane, md)
	local ok, err = pcall(function() cx.canvas:set(pane, { md = md }) end)
	if not ok then report(cx, err, "Visualize PR failed") end
end

-- A read-only outline of the worktree's pull request in a canvas tab. Nothing on
-- GitHub or in the checkout changes; see visualize.luau.
local function visualizePr(cx, path)
	local project, worktree = findWorktree(path)
	local entry = project and cache[project.id]
	local pr = entry and entry.prs and worktree.branch and entry.prs[worktree.branch]
	if not pr then report(cx, "No pull request found. Refresh Projects."); return end
	local key = project.id .. "#" .. tostring(pr.number)
	if outlines[key] and cx.canvas:get(outlines[key]) then cx.layout:focus(outlines[key]); return end
	local heading = "# PR #" .. tostring(pr.number) .. "\n\n"
	local pane, err = cx.canvas:open({
		title = "PR #" .. tostring(pr.number) .. " · Visual outline",
		about = "Read-only visual outline of pull request #" .. tostring(pr.number) .. " (" .. pr.url
			.. "), drafted by omp from its diff. Nothing on GitHub changes.",
		md = heading .. "Reading the pull request and drafting its outline with omp. This usually takes a minute or two; nothing on GitHub changes.",
		how = "tab",
	})
	if not pane then report(cx, err or "Could not open a canvas.", "Visualize PR failed"); return end
	outlines[key] = pane
	local ticket = ticketFor(project, worktree)
	visualize.outline(project, worktree, pr.number, ticket and ticket.url, function(md, outlineErr, nextCx)
		if not nextCx or not nextCx.canvas:get(pane) then return end
		if md then
			setOutline(nextCx, pane, md)
		else
			tern.log.warn("Visualize PR #" .. tostring(pr.number) .. " failed: " .. tostring(outlineErr))
			setOutline(nextCx, pane, heading .. "Couldn't draft the outline.\n\n```text\n" .. tostring(outlineErr) .. "\n```")
		end
	end)
end

-- A session to keep a removal's output tab in when the worktree being removed
-- is the current session: it closes on success, taking its tabs with it.
-- Prefers the project's primary checkout session, then any other session.
local function outputSession(cx, project, target)
	local sessions = sessionsById(cx)
	local primary = records("sessions")[project.path]
	if primary and primary.id ~= target.id and sessions[tostring(primary.id)] then return primary.id end
	for _, session in cx.sessions:list() do
		if session.id ~= target.id and session.host == target.host then return session.id end
	end
	return nil
end

-- Starts a deletion. Rechecks the worktree, then removes it straight away when
-- it's clean. With uncommitted changes and no `request.force` yet, it shows the
-- changes for you to confirm instead; confirming calls back here with force set.
local function beginRemoval(cx, request)
	local project = projectById(request.project)
	if not project then
		if confirmation == request then confirmation = nil end
		report(cx, "Project is no longer registered."); redraw(cx); return
	end
	removalChecks[request.path] = request
	redraw(cx)
	local function current(nextCx)
		-- Cancelling or reloading while a check runs never starts a deletion.
		return nextCx ~= nil and removalChecks[request.path] == request
	end
	local function failed(freshCx, text)
		removalChecks[request.path] = nil
		if confirmation == request then confirmation = nil end
		report(freshCx, text, "Worktree deletion failed")
		refresh(freshCx)
	end
	local function launch(nextCx, worktree, force)
		local _, guardError = closeGuard(nextCx, request.path)
		if guardError then failed(nextCx, guardError); return end
		local jobs = records("jobs")
		for _, job in jobs do
			if job.project == project.id and (job.path == worktree.path or (worktree.branch and job.branch == worktree.branch)) then
				failed(nextCx, "A Worktrunk operation is already running for this worktree."); return
			end
		end
		local jobId = token()
		local receipt = tern.plugin.data .. "/removal-" .. jobId .. ".status"
		local ready, command = pcall(wt.removal_command, project, worktree, receipt, force)
		if not ready then failed(nextCx, command); return end
		-- Like creation, the output tab opens in the background; you stay put.
		local terminal = nextCx.layout:new_tab({ cwd = project.path, command = command }, { focus = false })
		if not terminal then failed(nextCx, "Could not open the removal terminal."); return end
		local target = records("sessions")[worktree.path]
		if target and nextCx.sessions:current().id == target.id then
			-- This session closes on success; keep the output somewhere that survives.
			local keep = outputSession(nextCx, project, target)
			if keep then nextCx.layout:move_to_new_tab(terminal, keep, { focus = false }) end
		end
		local tabName = "Delete: " .. request.label
		local tab = nextCx.session:tab_of(terminal)
		if tab then nextCx.layout:name_tab(tab, tabName) end
		jobs[jobId] = {
			kind = "remove", project = project.id, path = worktree.path, branch = worktree.branch,
			label = request.label, receipt = receipt, pane = terminal, started = os.time(),
			session = target,
		}
		tern.kv.set("jobs", jobs)
		oplog.write("info", { op = "remove", event = "started", project = project.name, branch = worktree.branch,
			path = worktree.path, detail = if force then "forced" else nil })
		removalChecks[request.path] = nil
		if confirmation == request then confirmation = nil end
		nextCx:toast("info", "Deleting worktree", notificationLabel(request.label))
		redraw(nextCx)
	end
	wt.validate_removal(project, request.worktree, function(worktree, err, nextCx)
		if not current(nextCx) then return end
		if not worktree then failed(nextCx, err); return end
		if request.force or not worktree.dirty then launch(nextCx, worktree, request.force); return end
		-- A sub-worktree deleted along with its parent never loses work: keep it.
		if request.keepIfDirty then
			removalChecks[request.path] = nil
			nextCx:toast("info", "Kept sub-worktree", notificationLabel(request.label) .. " has uncommitted changes")
			redraw(nextCx)
			return
		end
		wt.local_changes(worktree.path, function(changes, changesError, changesCx)
			if not current(changesCx) then return end
			if not changes then failed(changesCx, changesError); return end
			-- Clean again by now: the helper still refuses if that changes before it runs.
			if changes.total == 0 then launch(changesCx, worktree, false); return end
			removalChecks[request.path] = nil
			request.worktree, request.changes, request.force = table.clone(worktree), changes, true
			confirmation = request
			redraw(changesCx)
		end)
	end)
end

-- Deletes a parent alone, or with its sub-worktrees. Each one goes through its
-- own check, in a callback of its own: clean ones go at once, a dirty
-- sub-worktree is kept, and a dirty parent asks for Force delete as usual.
local function deleteFamily(cx, request, all)
	confirmation = nil
	local project, parent = findWorktree(request.path)
	if not project then report(cx, "Worktree not found. Refresh Projects."); redraw(cx); return end
	if all then
		for _, child in request.children do
			separately("delete " .. child.label, function(nextCx)
				local childProject, worktree = findWorktree(child.path)
				if not childProject or removing(child.path) or removalChecks[child.path] then return end
				beginRemoval(nextCx, {
					id = token(), kind = "delete", path = child.path, label = worktree.branch or child.label,
					project = childProject.id, worktree = table.clone(worktree), force = false, keepIfDirty = true,
				})
			end)
		end
	end
	if removalChecks[request.path] then return end
	beginRemoval(cx, {
		id = token(), kind = "delete", path = request.path, label = request.label,
		project = project.id, worktree = table.clone(parent), force = false,
	})
end

local function confirmWorktreeAction(cx, id, all)
	local request = confirmation
	if not request or request.id ~= id or request.checking then return end
	if request.kind == "remove-project" then removeProject(cx, request); return end
	if request.kind == "coordination-on" then
		confirmation = nil
		setCoordination(cx, request.project, true)
		redraw(cx)
		return
	end
	if request.kind == "delete-family" then deleteFamily(cx, request, all == true); return end
	request.checking = true
	beginRemoval(cx, request)
end

-- Links `branch` under `parent` (nil: top level). The panel moves at once;
-- the links are read back afterwards, so what Worktrunk stored wins.
local function setParent(cx, project, branch, parent)
	local entry = cache[project.id]
	if entry then
		entry.parents = entry.parents or {}
		entry.parents[branch] = parent
		redraw(cx)
	end
	wt.set_var(project, branch, wt.PARENT_KEY, parent, function(ok, err, nextCx)
		if not ok and nextCx then report(nextCx, err, "Couldn't move the worktree") end
		if entry then refreshLinks(project, entry) end
	end)
end

-- Picks a new parent for a worktree among the top-level ones: a sub-worktree
-- can't own others, and a worktree's own sub-worktrees can't own it.
local function moveUnder(cx, path)
	local project, worktree = findWorktree(path)
	if not project or not worktree.branch then report(cx, "Worktree not found. Refresh Projects."); return end
	if worktree.is_main then report(cx, "The primary checkout can't be a sub-worktree."); return end
	local entry = cache[project.id]
	local ownerOf = owners(entry)
	local names = records("worktree-names")[project.id] or {}
	local link = entry.parents and entry.parents[worktree.branch]
	local items = {}
	for _, candidate in entry.worktrees do
		if candidate.branch and candidate.path ~= path and not ownerOf[candidate.path] then
			local name = names[candidate.path]
			table.insert(items, {
				label = name or candidate.branch, detail = if name then candidate.branch else nil,
				icon = "branch", current = link == candidate.branch, branch = candidate.branch,
			})
		end
	end
	if #items == 0 then report(cx, "No other worktree can own this one."); return end
	cx:pick({
		items = items, icon = "corner-down-right", action = "move",
		placeholder = "Move " .. (names[path] or worktree.branch) .. " under…",
	}):next(function(item, _err, nextCx)
		if not item or not nextCx or type(item.branch) ~= "string" then return end
		setParent(nextCx, project, worktree.branch, item.branch)
	end)
end

local function makeTopLevel(cx, path)
	local project, worktree = findWorktree(path)
	if not project or not worktree.branch then report(cx, "Worktree not found. Refresh Projects."); return end
	setParent(cx, project, worktree.branch, nil)
end

local function requestWorktreeAction(cx, kind, path)
	local project, worktree = findWorktree(path)
	local binding = records("sessions")[path]
	-- A worktree removed outside Overseer is no longer listed; only its session can be closed.
	if not project and not (kind == "close" and binding) then report(cx, "Worktree not found. Refresh Projects."); return end
	if removing(path) then report(cx, "This worktree is already being deleted."); return end
	local session, err = closeGuard(cx, path)
	if err then report(cx, err); return end
	local label = if worktree then worktree.branch or "Detached HEAD" else tostring(session and session.name or path)
	if kind == "close" then
		-- Closing a session needs no confirmation: the worktree's files stay.
		if not session then report(cx, "This worktree has no open session."); return end
		local ok, closeError = closeManagedSession(cx, path)
		if not ok then report(cx, closeError, "Session closure failed") else
			cx:toast("info", "Session closed", notificationLabel(label))
		end
		redraw(cx)
		return
	end
	if worktree.is_main or path == project.path then
		report(cx, "The primary checkout cannot be deleted."); return
	end
	if removalChecks[path] then return end
	-- A parent asks whether its sub-worktrees go too.
	local entry = cache[project.id]
	local ownerOf = owners(entry)
	local names = records("worktree-names")[project.id] or {}
	local family = {}
	for _, other in entry.worktrees do
		if ownerOf[other.path] == path then
			table.insert(family, { path = other.path, label = names[other.path] or other.branch or other.path, dirty = other.dirty })
		end
	end
	if #family > 0 then
		confirmation = {
			id = token(), kind = "delete-family", path = path, label = label, project = project.id, children = family,
		}
		redraw(cx)
		return
	end
	beginRemoval(cx, {
		id = token(), kind = "delete", path = path, label = label,
		project = project.id, worktree = table.clone(worktree), force = false,
	})
end

-- Forms take the Projects panel's place, like a page within it, and follow you
-- the same way; finishing or going back puts the panel back.
local function openForm(cx, mode, project, worktree)
	if not requireLocal(cx) then return end
	if worktree and removing(worktree.path) then report(cx, "This worktree is being deleted."); return end
	local current, kind = slot(cx)
	if kind == "form" then
		cx.layout:focus(current)
		cx:toast("info", "Form already open", "Finish it or go back to Projects.")
		return
	end
	if not current then
		-- Opening the panel and swapping it in one callback risks Tern's 50 ms budget.
		if not navigator(cx) then return end
		budget.later("open form", 0, function(nextCx)
			if nextCx and slot(nextCx) then openForm(nextCx, mode, project, worktree) end
		end)
		return
	end
	local names = worktree and records("worktree-names")[project.id]
	local id = token()
	local pane = swapSlot(cx, current, function()
		return cx:new_block("overseer.form", {
			id, mode,
			if worktree then worktree.branch or "Detached HEAD" else project and project.name or "",
			if worktree then names and names[worktree.path] or ""
				elseif mode == "linear" then project.linear or ""
				else project and project.base or "",
		}, "beside")
	end)
	if not pane then report(cx, "Reload the Overseer plugin.", "Form unavailable"); return end
	tern.kv.set("pending-form:" .. tostring(pane), {
		token = id, mode = mode, project = project and project.id, path = worktree and worktree.path,
	})
	watchForms()
end

local function rejectForm(cx, pane, err)
	inflight[pane] = nil
	local request = tern.kv.get("pending-form:" .. tostring(pane))
	if request then
		request.response = nil
		tern.kv.set("pending-form:" .. tostring(pane), request)
	end
	if cx.session:pane(pane) then
		cx.session:event(pane, { ev = "action", act = "retry", value = tostring(err) })
	else
		report(cx, err)
	end
end

-- Puts the Projects panel back in the form's place. The form's record goes
-- last: if Tern cuts this callback short, the next form check finds the
-- record and finishes again.
local function finishForm(cx, pane)
	if cx.session:pane(pane) then
		local data = model(cx)
		local navigatorPane = swapSlot(cx, pane, function()
			return cx.canvas:open({
				title = NAVIGATOR.title, about = NAVIGATOR.about, view = view.render(data), how = "beside",
			})
		end)
		if navigatorPane then
			rendered[navigatorPane] = tern.json.encode(data)
		else
			cx.layout:close(pane)
		end
	end
	tern.kv.set("pending-form:" .. tostring(pane), nil)
	inflight[pane] = nil
end

-- AppleScript for macOS's native folder picker; the start folder arrives as an
-- argument, so no path is ever spliced into the script text.
local CHOOSE_FOLDER = {
	"on run argv",
	'POSIX path of (choose folder with prompt "Choose a Git repository to add to Projects" default location (POSIX file (item 1 of argv)))',
	"end run",
}

-- Where the picker starts: beside the last project added, else ~/code, else ~.
local function pickerStart()
	local last = tern.kv.get("picker-start")
	if type(last) == "string" and tern.fs.exists(last) then return last end
	local home = tern.getenv("HOME") or "/"
	if tern.fs.exists(home .. "/code") then return home .. "/code" end
	return home
end

local picking = false
-- Defined below; addPicked reopens the picker after a non-repository choice.
local pickProject

local function addPicked(cx, path)
	wt.inspect(path, function(project, err, nextCx, notRepo)
		if not nextCx then return end
		if not project then
			if notRepo then
				-- Let them choose again, starting where they were.
				report(nextCx, err, "Not a Git repository")
				tern.kv.set("picker-start", path)
				pickProject(nextCx)
			else
				report(nextCx, err, "Project not added")
			end
			return
		end
		for _, existing in projects() do
			if existing.id == project.id then
				nextCx:toast("info", "Already in Projects", notificationLabel(existing.name))
				return
			end
		end
		if project.base == "" then
			report(nextCx, "Check out a branch, then add it again.", "No base branch found")
			return
		end
		local all = projects()
		table.insert(all, project)
		tern.kv.set("projects", all)
		tern.kv.set("picker-start", string.match(project.path, "^(.*)/[^/]+$") or project.path)
		nextCx:toast("info", "Project added", notificationLabel(project.name))
		navigator(nextCx)
	end)
end

-- Opens macOS's folder picker; choosing a Git repository adds it right away.
function pickProject(cx)
	if not requireLocal(cx) then return end
	if picking then
		cx:toast("info", "Folder picker already open", "Choose a folder or cancel it.")
		return
	end
	picking = true
	local argv = { "/usr/bin/osascript" }
	for _, line in CHOOSE_FOLDER do
		table.insert(argv, "-e")
		table.insert(argv, line)
	end
	table.insert(argv, pickerStart())
	-- The picker waits for the user; give up after 30 minutes untouched.
	wt.spawn(argv, { timeout_ms = 30 * 60 * 1000 }, function(result, nextCx, startErr)
		picking = false
		if not nextCx then return end
		if not result then report(nextCx, "Couldn't open the folder picker: " .. startErr, "Folder picker failed"); return end
		if result.status ~= 0 then
			-- Cancel (AppleScript error -128), timeouts, and pickers ended by a
			-- signal (status -1, e.g. a plugin reload) need no message.
			if result.status == -1 or string.find(result.stderr or "", "-128", 1, true) then return end
			report(nextCx, "Couldn't open the folder picker: " .. ((result.stderr or ""):match("^%s*(.-)%s*$")), "Folder picker failed")
			return
		end
		local path = (result.stdout or ""):match("^%s*(.-)%s*$")
		if #path > 1 then path = path:gsub("/+$", "") end
		addPicked(nextCx, path)
	end)
end

-- Display names are single-line labels for the Projects panel; blank means
-- "use the branch name".
local function normalizeName(raw)
	if raw == nil then return nil end
	if type(raw) ~= "string" or raw:find("[%c]") then
		return nil, "Use a single-line display name without control characters."
	end
	local name = raw:match("^%s*(.-)%s*$")
	return if name == "" then nil else name
end

-- Starts Worktrunk's creation of `job.branch` in a background tab and records
-- `job` for checkJobs. Returns an error message instead when it cannot start.
local function launchCreation(cx, project, job)
	for _, other in records("jobs") do
		if other.project == project.id and other.branch == job.branch then
			return "Creation is already running. Check its setup terminal."
		end
	end
	local id = token()
	local receipt = tern.plugin.data .. "/creation-" .. id .. ".status"
	local ready, command = pcall(wt.creation_command, project, job.branch, receipt)
	if not ready then return command end
	-- A background tab: the panel stays in front while setup runs.
	local terminal = cx.layout:new_tab({ cwd = project.path, command = command }, { focus = false })
	if not terminal then return "Could not open the creation terminal." end
	local tab = cx.session:tab_of(terminal)
	if tab then cx.layout:name_tab(tab, "Create: " .. job.branch) end
	job.kind, job.project, job.receipt, job.pane, job.started = "create", project.id, receipt, terminal, os.time()
	local jobs = records("jobs")
	jobs[id] = job
	tern.kv.set("jobs", jobs)
	oplog.write("info", { op = "create", event = "started", project = project.name, branch = job.branch })
	return nil
end

local function createWorktree(cx, pane, request, response)
	local project = projectById(request.project)
	if not project then rejectForm(cx, pane, "Project is no longer registered."); return end
	local displayName, nameError = normalizeName(response.name)
	if nameError then rejectForm(cx, pane, nameError); return end
	wt.validate(project, response.branch, function(ok, err, nextCx)
		if not nextCx then return end
		if not nextCx.session:pane(pane) then finishForm(nextCx, pane); return end
		if not ok then rejectForm(nextCx, pane, err); return end
		local launchError = launchCreation(nextCx, project, { branch = response.branch, displayName = displayName })
		if launchError then rejectForm(nextCx, pane, launchError); return end
		-- Never launched twice: finishing again after a cut-short callback skips this.
		request.launched = true
		tern.kv.set("pending-form:" .. tostring(pane), request)
		separately("finish form", function(finishCx) finishForm(finishCx, pane) end)
		nextCx:toast("info", "Creating worktree", notificationLabel(displayName or response.branch))
		redraw(nextCx)
	end)
end

local function renameWorktree(cx, pane, request, response)
	local project, worktree = findWorktree(request.path)
	if not project or project.id ~= request.project or not tern.fs.exists(request.path) then
		rejectForm(cx, pane, "Worktree is no longer available. Refresh Projects."); return
	end
	if removing(request.path) then rejectForm(cx, pane, "This worktree is being deleted."); return end
	local name, nameError = normalizeName(response.name)
	if nameError then rejectForm(cx, pane, nameError); return end
	local names = records("worktree-names")
	names[project.id] = names[project.id] or {}
	names[project.id][worktree.path] = name
	tern.kv.set("worktree-names", names)
	finishForm(cx, pane)
	cx:toast("info", if name == nil then "Branch label restored" else "Worktree renamed",
		notificationLabel(name or worktree.branch or "Detached HEAD"))
	redraw(cx)
end

-- New worktrees branch from the project's base; only an existing local branch is accepted.
local function changeBase(cx, pane, request, response)
	local project = projectById(request.project)
	if not project then rejectForm(cx, pane, "Project is no longer registered."); return end
	local base = type(response.base) == "string" and response.base:match("^%s*(.-)%s*$") or ""
	if base == "" or base:find("[%c%s]") or base:sub(1, 1) == "-" then
		rejectForm(cx, pane, "Enter a local branch name, such as main."); return
	end
	wt.spawn({ "git", "-C", project.path, "show-ref", "--verify", "--quiet", "refs/heads/" .. base },
		{ timeout_ms = 15000 }, function(result, nextCx, startErr)
			if not nextCx then return end
			if not nextCx.session:pane(pane) then finishForm(nextCx, pane); return end
			if not result then rejectForm(nextCx, pane, "Couldn't check the branch: " .. startErr); return end
			if result.status ~= 0 then
				rejectForm(nextCx, pane, "No local branch named " .. base .. " in " .. project.name .. ".")
				return
			end
			local all = projects()
			for _, existing in all do
				if existing.id == project.id then existing.base = base end
			end
			tern.kv.set("projects", all)
			finishForm(nextCx, pane)
			nextCx:toast("info", "Base branch changed", notificationLabel(project.name .. " → " .. base))
			redraw(nextCx)
		end)
end

-- Accepts a workspace name ("acme") or any link inside it ("https://linear.app/acme/issue/ENG-1").
local function changeLinear(cx, pane, request, response)
	local project = projectById(request.project)
	if not project then rejectForm(cx, pane, "Project is no longer registered."); return end
	local workspace, invalid = Prefs.linearWorkspace(response.linear)
	if not workspace then rejectForm(cx, pane, invalid); return end
	local all = projects()
	for _, existing in all do
		if existing.id == project.id then existing.linear = if workspace == "" then nil else workspace end
	end
	tern.kv.set("projects", all)
	finishForm(cx, pane)
	cx:toast("info", if workspace == "" then "Using the Linear CLI's workspace" else "Linear workspace set", notificationLabel(project.name))
	redraw(cx)
end

-- Brief sub-worktrees: your message goes to each sub-worktree's overseer
-- session now; one without a session gets it when it starts one.
local function sendBrief(cx, pane, request, response)
	local message = type(response.message) == "string" and response.message:match("^%s*(.-)%s*$") or ""
	if message == "" then rejectForm(cx, pane, "Enter a message."); return end
	local sent, err = briefChildren(cx, request.path, message)
	if not sent then rejectForm(cx, pane, err); return end
	finishForm(cx, pane)
	cx:toast("info", "Brief sent", "To " .. tostring(sent) .. " sub-worktree" .. (if sent == 1 then "" else "s") .. ".")
	redraw(cx)
end

-- The worktree's path is only known once Worktrunk has created it, so the
-- display name chosen at creation is attached afterwards, by branch.
local function applyCreatedName(job)
	local project = projectById(job.project)
	if not job.displayName or not project then return end
	wt.list(project, function(trees, _err, cx)
		if not trees or not cx then return end
		for _, tree in trees do
			if tree.branch == job.branch and not tree.is_main then
				local names = records("worktree-names")
				names[project.id] = names[project.id] or {}
				-- A rename made while setup ran wins over the name typed at creation.
				if names[project.id][tree.path] == nil then
					names[project.id][tree.path] = job.displayName
					tern.kv.set("worktree-names", names)
					redraw(cx)
				end
				return
			end
		end
	end)
end

-- A worktree created for a ticket gets an omp agent in its session, already
-- asked to read the ticket. Like the display name, its path is found by branch.
local function startTicketAgent(job)
	local project = projectById(job.project)
	if not job.agentPrompt or not project then return end
	wt.list(project, function(trees, err, cx)
		if not cx then return end
		if not trees then report(cx, err, "Agent not started"); return end
		for _, tree in trees do
			if tree.branch == job.branch and not tree.is_main then
				ensureSession(cx, project, tree.path, tree.branch)
				local ok, startError = pcall(function()
					cx.agents:start({ prompt = job.agentPrompt, cwd = tree.path, command = "omp", how = "tab" })
				end)
				if not ok then report(cx, startError, "Agent not started") end
				redraw(cx)
				return
			end
		end
		report(cx, "No worktree for " .. job.branch .. " after creation.", "Agent not started")
	end)
end

-- Acts on one form's response, in a callback of its own.
local function answerForm(cx, pane, request, response)
	if response.cancelled or request.launched then
		finishForm(cx, pane)
	elseif request.mode == "create" and response.mode == "create" then
		createWorktree(cx, pane, request, response)
	elseif request.mode == "rename" and response.mode == "rename" then
		renameWorktree(cx, pane, request, response)
	elseif request.mode == "base" and response.mode == "base" then
		changeBase(cx, pane, request, response)
	elseif request.mode == "linear" and response.mode == "linear" then
		changeLinear(cx, pane, request, response)
	elseif request.mode == "brief" and response.mode == "brief" then
		sendBrief(cx, pane, request, response)
	else
		rejectForm(cx, pane, "Invalid form response. Please try again.")
	end
end

local function forms(cx)
	for _, info in cx.session:panes() do
		local pane = info.pane
		if info.block == "overseer.form" and not inflight[pane] then
			local request = tern.kv.get("pending-form:" .. tostring(pane))
			if not request then
				-- A form without its record: Tern cut short the callback that opened
				-- it. It can never answer, so put Projects back.
				inflight[pane] = true
				separately("restore Projects", function(nextCx) finishForm(nextCx, pane) end)
			else
				local response = request.response or tern.kv.get("form:" .. request.token)
				if response then
					-- Keep validation inputs until completion so a plugin reload can
					-- resume an in-flight request without leaving a submitted form stuck.
					request.response = response
					tern.kv.set("pending-form:" .. tostring(pane), request)
					tern.kv.set("form:" .. request.token, nil)
					inflight[pane] = true
					separately("answer form", function(nextCx) answerForm(nextCx, pane, request, response) end)
				end
			end
		end
	end
end

-- Forms post their responses through kv, which has no change notification.
-- While one is open, check every 100 ms so Back and Submit feel immediate;
-- the 750 ms tick covers everything else.
local watching = false
watchForms = function()
	if watching then return end
	watching = true
	local function step(cx)
		if not cx then watching = false; return end
		local open = false
		for _, pane in cx.session:panes() do
			if pane.block == "overseer.form" then open = true; break end
		end
		if not open then watching = false; return end
		local ok, err = pcall(forms, cx)
		if not ok then tern.log.warn("Overseer form check failed: " .. tostring(err)) end
		budget.later("form check", 100, step)
	end
	budget.later("form check", 100, step)
end

-- The helper's receipt is the only authority on an operation's outcome. A
-- terminal that looks closed or missing is just a hint: Tern can misreport a
-- pane while its program keeps running in the session daemon. Report failure
-- only once the helper process is confirmed gone without writing a receipt.
local function helperFailed(id, job)
	if dead[id] then return true end
	if probing[id] then return false end
	local pidFile = job.receipt .. ".pid"
	if not tern.fs.exists(pidFile) then
		-- Allow the login shell time to start the helper before it writes its PID.
		return os.time() - (job.started or 0) >= 30
	end
	local pid = tonumber(tern.fs.read(pidFile))
	if not pid then return true end
	probing[id] = true
	wt.spawn({ "/bin/kill", "-0", tostring(pid) }, { timeout_ms = 5000 }, function(result)
		probing[id] = nil
		if result and result.status ~= 0 then dead[id] = true end
	end)
	return false
end

-- What a finished job leaves to do: close its tab, update names and sessions,
-- log it, and tell you. Runs in a callback of its own once the job is off the
-- books, so a callback Tern cuts short never repeats or misreports a job.
local function jobFinished(cx, job, status)
	local seconds = math.max(0, os.time() - (job.started or os.time()))
	-- Before the tab closes: a setup that printed warnings goes in the
	-- operation log, with its first warning, and nowhere else.
	local warnings = {}
	if cx.session:pane(job.pane) then
		warnings = oplog.warnings(oplog.readPane(cx, job.pane, oplog.READ_LINES, true) or {})
	end
	-- On success the output tab has served its purpose: close it (its helper is
	-- only waiting for Enter). Failures keep it open with the error on screen,
	-- including a deletion that reported success but left its directory.
	local succeeded = status == 0 and (job.kind ~= "remove" or not tern.fs.exists(job.path))
	if succeeded and cx.session:pane(job.pane) then cx.layout:close(job.pane) end
	local project = projectById(job.project)
	oplog.write(if succeeded and #warnings == 0 then "info" else "warn", {
		op = if job.kind == "remove" then "remove" else "create", event = if succeeded then "finished" else "failed",
		project = project and project.name, branch = job.branch, path = job.path, status = status, seconds = seconds,
		warnings = if #warnings > 0 then #warnings else nil, detail = warnings[1],
	})
	if job.kind == "remove" then
		if succeeded then
			local names = records("worktree-names")
			if names[job.project] then
				names[job.project][job.path] = nil
				tern.kv.set("worktree-names", names)
			end
			local icebox = records("icebox")
			if icebox[job.project] then
				icebox[job.project][job.path] = nil
				tern.kv.set("icebox", icebox)
			end
			local closed, closeError = true, nil
			if job.session then closed, closeError = closeManagedSession(cx, job.path, job.session) end
			if closed then
				cx:toast("info", "Worktree deleted", notificationLabel(job.label))
			else
				tern.log.warn("Worktree deleted, but its session was left open: " .. tostring(closeError))
				notify(cx, "error", "Worktree deleted", "Session still open",
					{ label = "Close session", action = "close-session=" .. job.path, hint = "Check Tern’s log." })
			end
		else
			-- The setup tab stays open with the error on screen, unless the helper died with it.
			local tab = if cx.session:pane(job.pane) then { label = "Show", action = "tab=" .. tostring(job.pane), hint = "Check the Delete tab." } else nil
			notify(cx, "error", "Worktree deletion failed", "Session kept", tab)
		end
	else
		-- Applied on failure too: a partially created worktree keeps its label.
		applyCreatedName(job)
		if status == 0 then
			-- A ticket worktree opens on its own, with its agent (startTicketAgent).
			local open = if job.agentPrompt then nil else {
				label = "Open", action = "open-branch=" .. job.branch .. ":" .. job.project,
			}
			notify(cx, "info", "Worktree created", notificationLabel(job.displayName or job.branch), open)
			startTicketAgent(job)
		else
			local tab = if cx.session:pane(job.pane) then { label = "Show", action = "tab=" .. tostring(job.pane), hint = "Check the Create tab for details." } else nil
			notify(cx, "error", "Worktree creation failed", nil, tab)
		end
	end
end

-- `inline` finishes jobs in this callback instead of one of their own: the
-- process clock does that when timers may not be running.
local function checkJobs(cx, inline)
	local jobs = records("jobs")
	local finished = {}
	for id, job in jobs do
		local status
		if tern.fs.exists(job.receipt) then
			status = tonumber(tern.fs.read(job.receipt)) or -1
		else
			local pane = cx.session:pane(job.pane)
			if (not pane or pane.exited ~= nil or pane.error) and helperFailed(id, job) then status = -1 end
		end
		if status ~= nil then finished[id] = { job = job, status = status } end
	end
	if next(finished) == nil then return end
	-- Off the books before the receipts go: a callback cut short in between
	-- leaves a stray receipt, never a job without one (which reads as failed).
	for id in finished do jobs[id] = nil end
	tern.kv.set("jobs", jobs)
	for id, done in finished do
		probing[id], dead[id] = nil, nil
		for _, file in { done.job.receipt, done.job.receipt .. ".pid" } do
			if tern.fs.exists(file) then tern.fs.remove(file) end
		end
		if inline then
			local ok, err = pcall(jobFinished, cx, done.job, done.status)
			if not ok then tern.log.warn("Overseer: finish job failed: " .. tostring(err)) end
		else
			separately("finish job", function(nextCx) jobFinished(nextCx, done.job, done.status) end)
		end
	end
	refresh(cx)
end

-- Creations' progress, read from their setup tab each tick: the step they're
-- on, and how long their output has been still. A question on the last line
-- (Worktrunk's hook approval prompt) marks one "needs you?" at once; so does
-- CREATE_QUIET_S without output, long enough that a quiet install or code
-- generation step doesn't trip it. Either tells you once. After a reload it
-- just starts over.
local CREATE_QUIET_S = 60

local function trackCreations(cx)
	local jobs = records("jobs")
	local changed = false
	for id, job in jobs do
		if job.kind == "create" and job.pane then
			local state = progress[id] or { changedAt = os.time() }
			progress[id] = state
			local lines = oplog.readPane(cx, job.pane, 15, false)
			if lines then
				local signature = table.concat(lines, "\n")
				if signature ~= state.signature then state.signature, state.changedAt = signature, os.time() end
				local step, asking = oplog.progress(lines)
				local quiet = os.time() - state.changedAt
				local needsYou = asking or quiet >= CREATE_QUIET_S
				-- The row shows elapsed time in 5 s steps: redraw when that, the step
				-- or the flag changes, not on every tick.
				local bucket = (os.time() - (job.started or os.time())) // 5
				if step ~= state.step or needsYou ~= state.needsYou or bucket ~= state.bucket then changed = true end
				state.step, state.asking, state.needsYou, state.bucket = step, asking, needsYou, bucket
				state.quiet = if needsYou and not asking then quiet else nil
				if needsYou and not state.told then
					state.told = true
					local project = projectById(job.project)
					local why = if asking then "It's asking a question in its setup tab"
						else "No output for " .. quiet .. " s. It may be waiting for an answer"
					notify(cx, "error", "Creating " .. (job.displayName or job.branch) .. " may need you", why,
						{ label = "Answer", action = "tab=" .. tostring(job.pane), hint = "Click its row." })
					oplog.write("warn", { op = "create", event = "needs-you", project = project and project.name,
						branch = job.branch, detail = why })
				end
			end
		end
	end
	for id in progress do
		if not jobs[id] then progress[id], changed = nil, true end
	end
	if changed then redraw(cx) end
end

-- The newest operation log entries, as a table over the shown tab (a glimpse:
-- a click outside or Esc puts it away). The full file stays in ops.log.
local LOG_SHOWN = 200
local function showLog(cx)
	local entries = oplog.recent(LOG_SHOWN)
	local pane, err = cx.canvas:open({
		title = "Overseer operation log", view = view.operationLog(entries), how = "glimpse",
		about = "What Overseer did: worktree creations and deletions, briefs, relays and coordination, newest first. Read-only.",
	})
	if not pane then report(cx, err or "Couldn't open the operation log.", "Operation log") end
end

-- Overseer settings: focuses the Settings tab, or opens one.
local function openSettings(cx)
	if not requireLocal(cx) then return end
	local found = settingsPane(cx)
	if found then cx.layout:focus(found.pane); return end
	if not cx:new_block(SETTINGS_BLOCK, {}, "tab") then report(cx, "Couldn't open Overseer settings.", "Settings") end
end

-- Commands, like clicks, only queue their work.
local function command(id, title, icon, keys, run)
	tern.command({ id = id, title = title, icon = icon, keys = keys, run = function(_cx)
		separately("command " .. id, run)
	end })
end
command("projects", "Show or hide Projects", "branch", { "cmd+alt+shift+p" }, togglePanel)
command("add", "Add project", "folder", nil, pickProject)
command("create", "Create worktree", "branch", nil, function(cx)
	local project = activeWorktree(cx)
	if project then openForm(cx, "create", project) else navigator(cx); cx:toast("info", "Choose a project", "Click + beside a project's name.") end
end)
command("ops-log", "Show Overseer's operation log", "list", nil, showLog)
command("settings", "Overseer settings", "gear", nil, openSettings)

-- Install or Connect on Settings' Integrations (settings.luau writes kv
-- `setup-request`): runs one of Prefs.SETUP in a new tab of the window it came
-- from, so you can answer the CLI's questions there.
local function runSetup(cx)
	local request = tern.kv.get("setup-request")
	if type(request) ~= "table" then return end
	if request.window and request.window ~= cx:window_key() then return end
	tern.kv.set("setup-request", nil)
	local setup = Prefs.SETUP[request.run]
	if not setup then return end
	local terminal = cx.layout:new_tab({ command = setup.command })
	if not terminal then report(cx, "Couldn't open a terminal for: " .. setup.command, setup.title); return end
	local tab = cx.session:tab_of(terminal)
	if tab then cx.layout:name_tab(tab, setup.title) end
	oplog.write("info", { op = "setup", event = "started", detail = setup.command })
end

local TICKET_PROMPT = "Please read ticket %s to understand your task and ask any questions you have before we start"

local function projectNames()
	local names = {}
	for _, project in projects() do table.insert(names, project.name) end
	if #names == 0 then return "No projects are registered in Overseer." end
	return "Overseer projects: " .. table.concat(names, ", ") .. "."
end

-- A project named (in any case) or given by path; otherwise the current session's.
local function ticketProject(cx, wanted)
	if wanted == nil then
		local project = activeWorktree(cx)
		if project then return project end
		return nil, "The current session isn't an Overseer worktree, so name the project. " .. projectNames()
	end
	if type(wanted) ~= "string" then return nil, "project must be a string." end
	for _, project in projects() do
		if string.lower(project.name) == string.lower(wanted) or project.path == wanted then return project end
	end
	return nil, "No project named '" .. wanted .. "'. " .. projectNames()
end

tern.carly.export("ticket_worktree", {
	sig = "(ticket: string, project: string?) -> {branch: string, project: string, status: string}",
	doc = "Creates worktree feature/<ticket> (a Linear id such as ENG-123) from the project's base branch. "
		.. "When its setup succeeds, opens the worktree's session and starts omp there, asked to read the ticket "
		.. "and come back with questions. project is a project name or path; omitted, the current session's project. "
		.. "Answers once creation starts; setup runs in a background Create tab. Fails if the branch already exists.",
}, function(ticket, wanted, cx, call)
	if not localHost(cx) then error("Switch to the local host first.", 0) end
	if type(ticket) ~= "string" or not string.match(string.upper(ticket), "^%u[%u%d]*%-%d+$") then
		error("Expected a ticket id such as ENG-123.", 0)
	end
	ticket = string.upper(ticket)
	local project, projectError = ticketProject(cx, wanted)
	if not project then error(projectError, 0) end
	local branch = "feature/" .. ticket
	wt.validate(project, branch, function(ok, err, nextCx)
		-- Cancelling Carly before validation finishes never starts a creation.
		if call.cancelled or not nextCx then return end
		if not ok then call:fail(err); return end
		local launchError = launchCreation(nextCx, project, {
			branch = branch, agentPrompt = string.format(TICKET_PROMPT, ticket),
		})
		if launchError then call:fail(launchError); return end
		nextCx:toast("info", "Creating worktree", notificationLabel(branch))
		redraw(nextCx)
		call:reply({
			branch = branch, project = project.name,
			status = "Setup is running in a background Create tab; omp starts in the worktree's session when it succeeds.",
		})
	end)
	return call:wait(30000)
end)

tern.carly.context(function()
	return "Overseer creates Linear-ticket worktrees with ticket_worktree. " .. projectNames()
end)

-- Ticket and pull request links open in a tab of their own. `cx:open` puts a
-- URL in a browser split beside the focused pane whatever `how` says, so the
-- new browser pane moves to a new tab (the panel follows it there).
local function openLink(cx, url)
	if type(url) ~= "string" or not url:match("^https://") then return end
	local before = {}
	for _, pane in cx.session:panes() do before[pane.pane] = true end
	cx:open(url, "tab")
	for _, pane in cx.session:panes() do
		if not before[pane.pane] and pane.kind == "browser" then
			cx.layout:move_to_new_tab(pane.pane)
			return
		end
	end
end

-- Open on the Worktree created toast: the job knew only the branch
-- (`<branch>:<project id>`; a branch name can't hold a colon), so find its path.
local function openBranch(cx, value)
	local branch, id = string.match(value or "", "^([^:]+):(.+)$")
	local project = id and projectById(id)
	if not project then report(cx, "Project not found. Refresh Projects."); return end
	for _, tree in (cache[project.id] and cache[project.id].worktrees or {}) do
		if tree.branch == branch and not tree.is_main then openWorktree(cx, tree.path); return end
	end
	wt.list(project, function(trees, err, nextCx)
		if not nextCx then return end
		if not trees then report(nextCx, err, "Worktree not opened"); return end
		for _, tree in trees do
			if tree.branch == branch and not tree.is_main then openWorktree(nextCx, tree.path); return end
		end
		report(nextCx, "No worktree for " .. branch .. ".", "Worktree not opened")
	end)
end

local function canvasAction(ev, cx)
	if ev.act == "settings" then
		openSettings(cx)
		return
	elseif ev.act == "link" then
		openLink(cx, ev.value)
		return
	end
	if not requireLocal(cx) then return end
	if ev.act == "add" then pickProject(cx)
	elseif ev.act == "refresh" then
		refreshByHand(cx)
	elseif ev.act == "collapse" then collapsed[ev.value] = not collapsed[ev.value]; redraw(cx)
	elseif ev.act == "fold" then folded[ev.value] = if folded[ev.value] then nil else true; redraw(cx)
	elseif ev.act == "move-under" then moveUnder(cx, view.worktreePath(ev.node))
	elseif ev.act == "make-top-level" then makeTopLevel(cx, view.worktreePath(ev.node))
	elseif ev.act == "create" then
		local project = projectById(ev.value)
		if project then openForm(cx, "create", project) end
	elseif ev.act == "open-worktree" then openWorktree(cx, ev.value)
	elseif ev.act == "icebox-add" or ev.act == "icebox-remove" then
		local project, worktree = findWorktree(view.worktreePath(ev.node))
		if not project then report(cx, "Worktree not found. Refresh Projects."); return end
		local icebox = records("icebox")
		icebox[project.id] = icebox[project.id] or {}
		icebox[project.id][worktree.path] = if ev.act == "icebox-add" then true else nil
		tern.kv.set("icebox", icebox)
		redraw(cx)
	elseif ev.act == "toggle-icebox" then
		tern.kv.set("show-icebox", tern.kv.get("show-icebox") == false)
		redraw(cx)
	elseif ev.act == "change-base" or ev.act == "set-linear" then
		local project = projectById(view.projectId(ev.node))
		if project then openForm(cx, if ev.act == "change-base" then "base" else "linear", project)
		else report(cx, "Project not found. Refresh Projects.") end
	elseif ev.act == "remove-project" then
		requestProjectRemoval(cx, view.projectId(ev.node))
	elseif ev.act == "coordination-on" then
		requestCoordination(cx, view.projectId(ev.node))
	elseif ev.act == "coordination-off" then
		setCoordination(cx, view.projectId(ev.node), false)
	elseif ev.act == "visualize" then
		visualizePr(cx, view.worktreePath(ev.node))
	elseif ev.act == "make-lead" then
		local path, tab = view.tabTarget(ev.node)
		if path then makeLead(cx, path, tab) else report(cx, "Tab not found. Refresh Projects.") end
	elseif ev.act == "brief-children" then
		local project, worktree = findWorktree(view.worktreePath(ev.node))
		if project then openForm(cx, "brief", project, worktree)
		else report(cx, "Worktree not found. Refresh Projects.") end
	elseif ev.act == "rename" then
		local project, worktree = findWorktree(view.worktreePath(ev.node))
		if project then openForm(cx, "rename", project, worktree)
		else report(cx, "Worktree not found. Refresh Projects.") end
	elseif ev.act == "close-session" then
		-- From a row's menu, or the Close session button on a toast (`value` is the path).
		requestWorktreeAction(cx, "close", view.worktreePath(ev.node) or ev.value)
	elseif ev.act == "open-branch" then openBranch(cx, ev.value)
	elseif ev.act == "restore-project" then restoreProject(cx, ev.value)
	elseif ev.act == "delete-worktree" then
		requestWorktreeAction(cx, "delete", view.worktreePath(ev.node))
	elseif ev.act == "confirm" then confirmWorktreeAction(cx, ev.value)
	elseif ev.act == "confirm-all" then confirmWorktreeAction(cx, ev.value, true)
	elseif ev.act == "cancel" then
		if confirmation and confirmation.id == ev.value then
			if removalChecks[confirmation.path] == confirmation then removalChecks[confirmation.path] = nil end
			confirmation = nil
			redraw(cx)
		end
	elseif ev.act == "tab" then
		local pane = tonumber(ev.value)
		if pane and cx.session:pane(pane) then cx.layout:focus(pane) end
	end
end

local CANVAS_ACTIONS = {}
for _, act in {
	"settings", "add", "refresh", "collapse", "create", "open-worktree", "link", "icebox-add", "icebox-remove",
	"toggle-icebox", "change-base", "set-linear", "remove-project", "visualize", "rename",
	"close-session", "delete-worktree", "confirm", "confirm-all", "cancel", "tab", "fold", "move-under", "make-top-level",
	"make-lead", "brief-children", "coordination-on", "coordination-off", "open-branch", "restore-project",
} do CANVAS_ACTIONS[act] = true end

-- Clicks only queue their work: an overrun here would pause the hook and
-- swallow clicks until the pause ends, so it must stay too small to trip.
tern.on("canvas_action", function(ev, _cx)
	if not CANVAS_ACTIONS[ev.act] then return false end
	ensureTicking("click")
	separately("click " .. ev.act, function(nextCx) canvasAction(ev, nextCx) end)
	return true
end)

-- ⌘T in a worktree's session opens the tab in the worktree, running what a
-- built-in new tab runs: the agent command when Settings › New tabs and splits
-- open is Agent, else the login shell.
tern.override("new_tab", function(cx)
	if not localHost(cx) then return false end
	local _, worktree = activeWorktree(cx)
	if not worktree then return false end
	local launch: { cwd: string, command: string? } = { cwd = worktree.path }
	if string.lower(tostring(cx.settings:get("new_blocks"))) == "agent" then
		launch.command = cx.settings:get("agent_command")
	end
	cx.layout:new_tab(launch)
	return true
end)

tern.chrome.status(function()
	return { { text = "Projects", icon = "branch", command = "plugin.overseer.projects" } }
end)

-- Moves the panel into the shown tab and draws it, in a callback of its own;
-- changes made before it runs share it. `quiet` skips the draw: the tick
-- follows every 750 ms but only needs to draw for its clocks (elapsed times,
-- "checked in"), and a draw every tick kept Overseer near Tern's budget, so
-- a busy machine tripped it and paused every timer.
local followQueued, followDraws = false, false
local TICK_DRAW_MS = 5000
local lastTickDraw = -TICK_DRAW_MS
local function followSoon(quiet)
	followDraws = followDraws or not quiet
	if followQueued then return end
	followQueued = true
	budget.later("follow", 0, function(cx)
		followQueued = false
		local drawIt = followDraws
		followDraws = false
		if not cx then return end
		local ok, err = pcall(follow, cx)
		if not ok then tern.log.warn("Projects panel: " .. tostring(err)) end
		ok, err = pcall(markSeen, cx)
		if not ok then tern.log.warn("Overseer: agent marks: " .. tostring(err)) end
		if drawIt then redraw(cx) end
	end)
end

-- Each piece of a tick runs in a callback of its own. The next tick is
-- queued first, so an error can't stop the ticks.
--
-- The tick has stopped for long stretches without Tern pausing or logging
-- anything (2.3.0: jobs left unfinished for an hour until something restarted
-- it), so its health is watched from outside the timer hook: a generation
-- number lets a restart retire a lost chain, and `ensureTicking` runs from
-- every event and from a clock driven by a process (the process hook has a
-- budget of its own), restarting the tick when it is overdue.
local TICK_MS = 750
local TICK_STALL_MS = 5000
local tickGeneration = 0
local lastTick = tern.now()
-- When Tern paused the timer hook, until when (tern.now() ms); 0 when running.
local timerPausedUntil = 0
local tick
local settingsRev = tern.kv.get("settings-rev")

local function scheduleTick(generation)
	budget.later("tick", TICK_MS, function(cx) tick(generation, cx) end)
end

tick = function(generation, cx)
	-- A chain a restart replaced ends here, so two never run side by side.
	if generation ~= tickGeneration then return end
	scheduleTick(generation)
	lastTick = tern.now()
	if not cx or not localHost(cx) then return end
	-- Settings changed (settings.luau bumps the rev): read Git config and the
	-- listings again, and draw.
	local rev = tern.kv.get("settings-rev")
	if rev ~= settingsRev then
		settingsRev = rev
		separately("settings changed", function(nextCx)
			refresh(nextCx)
			redraw(nextCx)
		end)
	end
	if tern.kv.get("setup-request") ~= nil then separately("setup", runSetup) end
	separately("form check", forms)
	-- Resumes fast form checks after a plugin reload left a form open.
	watchForms()
	separately("job check", checkJobs)
	separately("creation progress", trackCreations)
	-- A hidden panel still refreshes, more slowly: the rails relay from what it knows.
	local interval = if #cx.canvas:list() > 0 then 15000 else 60000
	if tern.now() - lastRefresh >= interval then
		lastRefresh = tern.now()
		separately("refresh", refresh)
	end
	separately("mail", deliverMail)
	separately("rails", flushRails)
	-- Events draw at once; the tick only for its clocks, every few seconds.
	local clocks = tern.now() - lastTickDraw >= TICK_DRAW_MS
	if clocks then lastTickDraw = tern.now() end
	followSoon(not clocks)
end

-- Restarts the tick when it is overdue and Tern hasn't paused the timer hook
-- (a pause holds due timers on purpose). Returns whether it restarted.
ensureTicking = function(source)
	local now = tern.now()
	local gap = now - lastTick
	if gap < TICK_STALL_MS or now < timerPausedUntil then return false end
	tickGeneration += 1
	lastTick = now
	scheduleTick(tickGeneration)
	oplog.write("warn", { op = "tick", event = "restarted",
		detail = string.format("no tick for %.0f s; restarted from %s", gap / 1000, source) })
	return true
end

-- A second clock, outside the timer hook: a short process every 5 s. When the
-- tick turns out to be overdue it is restarted. While timers can't run (the
-- tick was overdue, or Tern paused the timer hook, which doubles to minutes on
-- repeat trips), this clock finishes jobs whose receipts are in and keeps the
-- panel in the shown tab, so neither waits for timers to come back.
local function processClock()
	local ok = pcall(budget.process, "clock", { "/bin/sleep", "5" }, { timeout_ms = 15000 }, function(_result, cx)
		processClock()
		if not cx or not localHost(cx) then return end
		local restarted = ensureTicking("the process clock")
		if restarted or tern.now() < timerPausedUntil then
			checkJobs(cx, true)
			local followed, err = pcall(follow, cx)
			if not followed then tern.log.warn("Projects panel: " .. tostring(err)) end
		end
	end)
	-- Can't start a process (shouldn't happen): events still check the tick.
	if not ok then tern.log.warn("Overseer: the process clock could not start") end
end

tern.on("window_start", function(_cx)
	separately("refresh", refresh)
	followSoon()
end)
-- Every tab, pane and focus change moves the panel into the shown tab.
for _, name in { "focus", "tab_created", "tab_closed", "pane_created", "pane_closed" } do
	tern.on(name, function(_ev, _cx)
		ensureTicking(name)
		followSoon()
	end)
end
-- An agent starting again clears its finished mark; any change redraws. The
-- rails record and relay the change, and an agent appearing or leaving can
-- change a worktree's overseer session.
tern.on("agent_state", function(ev, _cx)
	ensureTicking("agent_state")
	agentStates[ev.pane] = ev.new
	if ev.new == "working" or ev.new == "waiting_input" then
		separately("agent state", function() setFinished(ev.pane, nil) end)
		separately("rails agent", function(cx)
			if cx then onAgentChange(cx, ev.pane, if ev.new == "working" then "working" else "waiting") end
		end)
	end
	if ev.old == nil or ev.new == "exited" then
		separately("rails leads", function(cx) if cx then syncAllLeads(cx) end end)
	end
	followSoon()
end)
-- A turn that ends out of sight leaves a done or failed mark until you look.
tern.on("agent_finished", function(ev, _cx)
	if ev.result == "done" or ev.result == "failed" then
		separately("agent finished", function(cx)
			local info = cx.session:pane(ev.pane)
			if info and info.tab ~= shownTab(cx) then setFinished(ev.pane, ev.result) end
		end)
		separately("rails agent", function(cx)
			if cx then onAgentChange(cx, ev.pane, ev.result) end
		end)
	else
		separately("rails leads", function(cx) if cx then syncAllLeads(cx) end end)
	end
	followSoon()
end)
-- Tern pauses a hook whose callback ran over its budget; due timers and
-- process results wait for the pause, so catching up is one follow and draw.
tern.on("budget", function(ev, _cx)
	tern.log.warn(budget.describe(ev))
	if ev.hook == "timer" then
		timerPausedUntil = if ev.state == "paused" then tern.now() + (ev.paused_ms or 0) + 1000 else 0
	end
	if ev.state == "resumed" then followSoon() end
end)
-- Timers are restarted on reload; window_start intentionally is not.
scheduleTick(tickGeneration)
processClock()
-- Every load, so a fresh install or an upgrade to a new plugin dir links omp to this copy.
budget.later("omp link", 0, function() omplink.ensure() end)
-- 2.1's self-reload cooldown; nothing reads it any more.
tern.kv.set("self-reload", nil)
