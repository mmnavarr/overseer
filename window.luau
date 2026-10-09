--!nonstrict
local wt = require("./worktrunk")
local view = require("./view")
local visualize = require("./visualize")

local cache = {}
local inflight = {}
-- Helper liveness probes: job id -> true while `kill -0` runs; dead[id] once it failed.
local probing, dead = {}, {}
local rendered = {}
local collapsed = {}
local confirmation
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

-- Agent activity in this window: "waiting" (it asked you something) or
-- "working", per session id (as a string), per tab id and per pane id.
-- Native agent blocks such as omp report their state;
-- their `busy` stays set while they sit idle, so it isn't consulted for them.
-- Agent CLIs in plain terminals only report progress, which Tern exposes as
-- `busy` (a CLI that hasn't reported progress yet counts as busy while it runs).
local function agentActivity(cx)
	local tabSession = {}
	for _, tab in cx.session:tabs() do tabSession[tab.id] = tostring(tab.session) end
	local activity = { sessions = {}, tabs = {}, panes = {} }
	local function mark(pane, tab, state)
		activity.panes[pane] = state
		-- Waiting wins: it is the state that needs you.
		local session = tabSession[tab] or ""
		if activity.sessions[session] ~= "waiting" then activity.sessions[session] = state end
		if activity.tabs[tab] ~= "waiting" then activity.tabs[tab] = state end
	end
	for _, agent in cx.agents:list() do
		local state = if agent.state == "waiting_input" then "waiting"
			elseif agent.state == "working" then "working"
			else nil
		local info = state and cx.session:pane(agent.pane)
		if info and info.tab then mark(agent.pane, info.tab, state) end
	end
	for _, pane in cx.session:panes() do
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
	local panesByTab = {}
	for _, pane in cx.session:panes() do
		if pane.tab then
			panesByTab[pane.tab] = panesByTab[pane.tab] or {}
			table.insert(panesByTab[pane.tab], pane)
		end
	end
	local rows = {}
	for _, tab in cx.session:tabs() do
		local panes = panesByTab[tab.id] or {}
		local chosen, hasAgent = nil, false
		for _, pane in panes do
			if pane.kind == "agent" then hasAgent = true end
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
			id = tab.id, pane = tab.pane,
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

local function model(cx)
	local sessions = sessionsById(cx)
	local names = records("worktree-names")
	local bindings, jobs = records("sessions"), records("jobs")
	local icebox = records("icebox")
	local showIcebox = tern.kv.get("show-icebox") ~= false
	local activity = agentActivity(cx)
	local tabs = tabRows(cx, activity)
	local result = {
		projects = {}, collapsed = collapsed, confirmation = confirmation,
		showIcebox = showIcebox, refreshing = spinning,
	}
	local current = cx.sessions:current()
	for _, project in projects() do
		local entry = cache[project.id]
		local row = {
			id = project.id, name = project.name, path = project.path, base = project.base,
			loading = not entry or entry.loading, error = entry and entry.error, worktrees = {}, hiddenIced = 0,
			total = entry and entry.worktrees and #entry.worktrees or 0,
		}
		local iced = {}
		for _, worktree in (entry and entry.worktrees or {}) do
			local item = table.clone(worktree)
			item.deleting = removing(worktree.path, jobs)
			item.displayName = names[project.id] and names[project.id][worktree.path]
			item.pr = not worktree.is_main and worktree.branch and entry.prs and entry.prs[worktree.branch] or nil
			item.ticket = ticketFor(project, worktree)
			local session = boundSession(worktree.path, sessions, bindings)
			item.session, item.tabs = session, session and tabs[tostring(session.id)] or {}
			item.agent = session and activity.sessions[tostring(session.id)]
			local active = session ~= nil and session.id == current.id
			if active then result.activePath = worktree.path end
			item.iced = not worktree.is_main and icebox[project.id] ~= nil and icebox[project.id][worktree.path] == true
			if not item.iced then
				table.insert(row.worktrees, item)
			elseif showIcebox or active then
				-- The active worktree stays visible even while the Ice Box is hidden.
				table.insert(iced, item)
			else
				row.hiddenIced += 1
			end
		end
		-- Ice Box worktrees sink to the bottom, keeping their relative order.
		for _, item in iced do table.insert(row.worktrees, item) end
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

local function draw(cx)
	local pane, kind = slot(cx)
	if not pane or kind ~= "canvas" then return end
	-- A just-opened canvas only accepts updates once canvas:list() reports it.
	local ready = false
	for _, canvas in cx.canvas:list() do
		if canvas.pane == pane then ready = true end
	end
	if not ready then return end
	local data = model(cx)
	local signature = tern.json.encode(data)
	if rendered[pane] == signature then return end
	cx.canvas:set(pane, { view = view.render(data) })
	rendered[pane] = signature
end

-- Asks for a draw soon, in a timer callback of its own. Tern gives each hook
-- callback 50 ms and disables the hook for the rest of the session after one
-- overrun, so clicks and process results never draw inline; requests made
-- before the draw runs share it.
local drawQueued = false
local function redraw(_cx)
	if drawQueued then return end
	drawQueued = true
	tern.timer(0, function(cx)
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
			wt.list(project, function(worktrees, err, nextCx)
				entry.loading, entry.error = false, err
				if worktrees then entry.worktrees = worktrees end
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
		if left > 0 then tern.timer(left, stop) else stop(doneCx) end
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

-- The panel's share of the tab when it is the tab's whole left side.
local function leftShare(cx, tab, pane)
	local layout = cx.session:layout(tab)
	local root = layout and layout.root
	if root and root.split == "right" and root[1] and root[1].pane == pane then return root.ratio end
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

local function openWorktree(cx, path)
	if not requireLocal(cx) then return end
	if removing(path) then report(cx, "Check the Delete tab.", "Deletion in progress"); return end
	local project, worktree = findWorktree(path)
	if not project then report(cx, "Worktree not found. Refresh Projects."); return end
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

local function requestWorktreeAction(cx, kind, path)
	local project, worktree = findWorktree(path)
	if not project then report(cx, "Worktree not found. Refresh Projects."); return end
	if removing(path) then report(cx, "This worktree is already being deleted."); return end
	local session, err = closeGuard(cx, path)
	if err then report(cx, err); return end
	if kind == "close" and not session then report(cx, "This worktree has no open session."); return end
	if kind == "delete" and (worktree.is_main or path == project.path) then
		report(cx, "The primary checkout cannot be deleted."); return
	end
	confirmation = {
		id = token(), kind = kind, path = path, label = worktree.branch or "Detached HEAD",
		project = project.id, worktree = table.clone(worktree),
	}
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

local function confirmWorktreeAction(cx, id)
	local request = confirmation
	if not request or request.id ~= id or request.checking then return end
	if request.kind == "close" then
		confirmation = nil
		local ok, err = closeManagedSession(cx, request.path)
		if not ok then report(cx, err, "Session closure failed") else
			cx:toast("info", "Session closed", notificationLabel(request.label))
		end
		redraw(cx)
		return
	end
	local project = projectById(request.project)
	if not project then confirmation = nil; report(cx, "Project is no longer registered."); redraw(cx); return end
	request.checking = true
	redraw(cx)
	wt.validate_removal(project, request.worktree, function(worktree, err, nextCx)
		-- Cancelling or reloading while validation runs never starts a deletion.
		if not nextCx or confirmation ~= request then return end
		local function failed(freshCx, text)
			confirmation = nil
			report(freshCx, text, "Worktree deletion failed")
			refresh(freshCx)
		end
		if not worktree then failed(nextCx, err); return end
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
		local ready, command = pcall(wt.removal_command, project, worktree, receipt)
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
		confirmation = nil
		nextCx:toast("info", "Deleting worktree", notificationLabel(request.label))
		redraw(nextCx)
	end)
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
		tern.timer(0, function(nextCx)
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

local function finishForm(cx, pane)
	inflight[pane] = nil
	tern.kv.set("pending-form:" .. tostring(pane), nil)
	if not cx.session:pane(pane) then return end
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
	tern.process.run(argv, { timeout_ms = 30 * 60 * 1000 }, function(result, nextCx)
		picking = false
		if not nextCx then return end
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
		finishForm(nextCx, pane)
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
	tern.process.run({ "git", "-C", project.path, "show-ref", "--verify", "--quiet", "refs/heads/" .. base },
		{ timeout_ms = 15000 }, function(result, nextCx)
			if not nextCx then return end
			if not nextCx.session:pane(pane) then finishForm(nextCx, pane); return end
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
	local raw = type(response.linear) == "string" and response.linear:match("^%s*(.-)%s*$") or ""
	local workspace = string.lower(raw:match("linear%.app/([^/?#]+)") or raw)
	if workspace ~= "" and not workspace:match("^[%w][%w%-]*$") then
		rejectForm(cx, pane, "Enter a workspace name such as acme, or a linear.app link."); return
	end
	local all = projects()
	for _, existing in all do
		if existing.id == project.id then existing.linear = if workspace == "" then nil else workspace end
	end
	tern.kv.set("projects", all)
	finishForm(cx, pane)
	cx:toast("info", if workspace == "" then "Using the Linear CLI's workspace" else "Linear workspace set", notificationLabel(project.name))
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

local function forms(cx)
	for _, pane in cx.session:panes() do
		if pane.block == "overseer.form" and not inflight[pane.pane] then
			local request = tern.kv.get("pending-form:" .. tostring(pane.pane))
			if request then
				local response = request.response or tern.kv.get("form:" .. request.token)
				if response then
					-- Keep validation inputs until completion so a plugin reload can
					-- resume an in-flight request without leaving a submitted form stuck.
					request.response = response
					tern.kv.set("pending-form:" .. tostring(pane.pane), request)
					tern.kv.set("form:" .. request.token, nil)
					inflight[pane.pane] = true
					if response.cancelled then
						finishForm(cx, pane.pane)
					elseif request.mode == "create" and response.mode == "create" then
						createWorktree(cx, pane.pane, request, response)
					elseif request.mode == "rename" and response.mode == "rename" then
						renameWorktree(cx, pane.pane, request, response)
					elseif request.mode == "base" and response.mode == "base" then
						changeBase(cx, pane.pane, request, response)
					elseif request.mode == "linear" and response.mode == "linear" then
						changeLinear(cx, pane.pane, request, response)
					else
						rejectForm(cx, pane.pane, "Invalid form response. Please try again.")
					end
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
		tern.timer(100, step)
	end
	tern.timer(100, step)
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
	tern.process.run({ "/bin/kill", "-0", tostring(pid) }, { timeout_ms = 5000 }, function(result)
		probing[id] = nil
		if result and result.status ~= 0 then dead[id] = true end
	end)
	return false
end

local function checkJobs(cx)
	local jobs = records("jobs")
	local changed = false
	for id, job in jobs do
		local status
		if tern.fs.exists(job.receipt) then
			status = tonumber(tern.fs.read(job.receipt))
			if status == nil then status = -1 end
			tern.fs.remove(job.receipt)
		else
			local pane = cx.session:pane(job.pane)
			if (not pane or pane.exited ~= nil or pane.error) and helperFailed(id, job) then status = -1 end
		end
		-- On success the output tab has served its purpose: close it (its helper is
		-- only waiting for Enter). Failures keep it open with the error on screen,
		-- including a deletion that reported success but left its directory.
		local succeeded = status == 0 and (job.kind ~= "remove" or not tern.fs.exists(job.path))
		if succeeded and cx.session:pane(job.pane) then cx.layout:close(job.pane) end
		if status ~= nil then
			jobs[id], changed = nil, true
			probing[id], dead[id] = nil, nil
			if tern.fs.exists(job.receipt .. ".pid") then tern.fs.remove(job.receipt .. ".pid") end
			if job.kind == "remove" then
				if status == 0 and not tern.fs.exists(job.path) then
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
						cx:toast("error", "Worktree deleted", "Session still open. Check Tern’s log.")
					end
				else
					cx:toast("error", "Worktree deletion failed", "Check the Delete tab. Session kept.")
				end
			else
				-- Applied on failure too: a partially created worktree keeps its label.
				applyCreatedName(job)
				local label = job.displayName or job.branch
				if status == 0 then
					cx:toast("info", "Worktree created", notificationLabel(label))
					startTicketAgent(job)
				else
					cx:toast("error", "Worktree creation failed", "Check the Create tab for details.")
				end
			end
		end
	end
	if changed then
		tern.kv.set("jobs", jobs)
		refresh(cx)
	end
end

tern.command({ id = "projects", title = "Show or hide Projects", icon = "branch", keys = { "cmd+alt+shift+p" }, run = togglePanel })
tern.command({ id = "add", title = "Add project", icon = "folder", run = function(cx) pickProject(cx) end })
tern.command({ id = "create", title = "Create worktree", icon = "branch", run = function(cx)
	local project = activeWorktree(cx)
	if project then openForm(cx, "create", project) else navigator(cx); cx:toast("info", "Choose a project", "Click + beside a project's name.") end
end })

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

tern.on("canvas_action", function(ev, cx)
	if ev.act == "help" then
		cx.docs:open(tern.plugin.dir .. "/README.md", { how = "tab" })
		return true
	end
	if not requireLocal(cx) then return true end
	if ev.act == "add" then pickProject(cx)
	elseif ev.act == "refresh" then
		refreshByHand(cx)
	elseif ev.act == "collapse" then collapsed[ev.value] = not collapsed[ev.value]; redraw(cx)
	elseif ev.act == "create" then
		local project = projectById(ev.value)
		if project then openForm(cx, "create", project) end
	elseif ev.act == "open" then openWorktree(cx, ev.value)
	elseif ev.act == "Add to Ice Box" or ev.act == "Remove from Ice Box" then
		-- Menu entries show their action verbatim, so these read as titled.
		local project, worktree = findWorktree(view.worktreePath(ev.node))
		if not project then report(cx, "Worktree not found. Refresh Projects."); return true end
		local icebox = records("icebox")
		icebox[project.id] = icebox[project.id] or {}
		icebox[project.id][worktree.path] = if ev.act == "Add to Ice Box" then true else nil
		tern.kv.set("icebox", icebox)
		redraw(cx)
	elseif ev.act == "toggle-icebox" then
		tern.kv.set("show-icebox", tern.kv.get("show-icebox") == false)
		redraw(cx)
	elseif ev.act == "Change base branch" or ev.act == "Set Linear workspace" then
		local project = projectById(view.projectId(ev.node))
		if project then openForm(cx, if ev.act == "Change base branch" then "base" else "linear", project)
		else report(cx, "Project not found. Refresh Projects.") end
	elseif ev.act == "Visualize PR" then
		visualizePr(cx, view.worktreePath(ev.node))
	elseif ev.act == "Rename" then
		local project, worktree = findWorktree(view.worktreePath(ev.node))
		if project then openForm(cx, "rename", project, worktree)
		else report(cx, "Worktree not found. Refresh Projects.") end
	elseif ev.act == "Close session" then
		requestWorktreeAction(cx, "close", view.worktreePath(ev.node))
	elseif ev.act == "Delete worktree" then
		requestWorktreeAction(cx, "delete", view.worktreePath(ev.node))
	elseif ev.act == "confirm" then confirmWorktreeAction(cx, ev.value)
	elseif ev.act == "cancel" then
		if confirmation and confirmation.id == ev.value then confirmation = nil; redraw(cx) end
	elseif ev.act == "tab" then
		local pane = tonumber(ev.value)
		if pane and cx.session:pane(pane) then cx.layout:focus(pane) end
	else return false end
	return true
end)

tern.override("new_tab", function(cx)
	if not localHost(cx) then return false end
	local _, worktree = activeWorktree(cx)
	if not worktree then return false end
	cx.layout:new_tab({ cwd = worktree.path })
	return true
end)

tern.chrome.status(function()
	return { { text = "Projects", icon = "branch", command = "plugin.overseer.projects" } }
end)

-- Runs fn in a timer callback of its own, reporting (not raising) errors.
-- Tern gives every callback its own 50 ms budget and disables a plugin's timers
-- after an overrun, so no single callback should carry all of a tick's work.
local function separately(fn)
	tern.timer(0, function(cx)
		if not cx then return end
		local ok, err = pcall(fn, cx)
		if not ok then
			local text = tostring(err)
			if problem ~= text then report(cx, text) end
		end
	end)
end

local function tick(cx)
	local ok, err = pcall(function()
		if not localHost(cx) then return end
		forms(cx)
		-- Resumes fast form checks after a plugin reload left a form open.
		watchForms()
		checkJobs(cx)
		if tern.now() - lastRefresh >= 15000 and #cx.canvas:list() > 0 then
			lastRefresh = tern.now()
			separately(refresh)
		end
		follow(cx)
		redraw(cx)
	end)
	if not ok then
		local text = tostring(err)
		if problem ~= text then report(cx, text) end
	end
	tern.timer(750, tick)
end

tern.on("window_start", function(cx)
	refresh(cx)
	follow(cx)
end)
-- Every tab, pane and focus change moves the panel into the shown tab and
-- draws it; any one of these hooks keeps it following if another is disabled.
local function followAndDraw(cx, tab)
	local ok, err = pcall(function()
		follow(cx, tab)
		draw(cx)
	end)
	if not ok then tern.log.warn("Projects panel: " .. tostring(err)) end
end
tern.on("focus", function(ev, cx) followAndDraw(cx, ev.tab) end)
for _, name in { "tab_created", "tab_closed", "pane_created", "pane_closed" } do
	tern.on(name, function(_ev, cx) followAndDraw(cx) end)
end
-- Timers are restarted on reload; window_start intentionally is not.
tern.timer(750, tick)
