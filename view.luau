local ui = tern.ui
local View = {}

local function safeKey(value)
	return (string.gsub(value, ".", function(byte)
		return string.format("%02x", string.byte(byte))
	end))
end

local function unhex(hex)
	if not hex or #hex % 2 ~= 0 then return nil end
	return (string.gsub(hex, "..", function(byte)
		return string.char(tonumber(byte, 16))
	end))
end

-- Menu rows send only their id; the target comes from the keyed row node the
-- menu belongs to, so ids stay plain and paths never travel through labels.
function View.worktreePath(node)
	return unhex(type(node) == "string" and node:match("%.w(%x+)%.row$") or nil)
end

function View.projectId(node)
	return unhex(type(node) == "string" and node:match("%.p(%x+)%.header$") or nil)
end

-- A tab row's worktree path and tab id, from its node id (`…w<hex>.tab<id>`).
function View.tabTarget(node)
	if type(node) ~= "string" then return nil, nil end
	local hex, tab = node:match("%.w(%x+)%.tab(%d+)$")
	return unhex(hex), tonumber(tab)
end

local function text(key, value, role, props)
	props = props or {}
	props.key, props.text, props.role = key, value, role
	return ui.node("text", props)
end

-- Tern's own button: its look, sizes, toggle, spinner and keycaps come from
-- `variant`, `size`, `on`, `busy` and `keys`, with no CSS of ours.
local function button(key, label, action, props)
	props = props or {}
	props.key, props.actions = key, { click = action }
	return ui.button(label, props)
end

local function badge(key, label, tone, title)
	return ui.node("badge", { key = key, text = label, tone = tone, title = title })
end

local PR_STATES = {
	draft = { role = "overseer.prDraft", label = "Draft" },
	open = { role = "overseer.prOpen", label = "Open" },
	merged = { role = "overseer.prMerged", label = "Merged" },
	closed = { role = "overseer.prClosed", label = "Closed" },
}

-- How each agent state shows: on the worktree row (a filled mark, or a
-- pulsing dot for working) and on its tab rows (a small dot, plus a label for
-- done and failed; the yellow dot says waiting on its own).
local AGENT_STATUS = {
	waiting = { role = "overseer.statusWaiting", title = "Agent waiting for you", tabRole = "overseer.dotTabWaiting" },
	failed = {
		role = "overseer.statusFailed", title = "Agent failed",
		tabRole = "overseer.dotTabFailed", label = "Failed", labelTone = "error",
	},
	done = {
		role = "overseer.statusDone", title = "Agent finished",
		tabRole = "overseer.dotTabDone", label = "Done", labelTone = "success",
	},
	working = { role = "overseer.dotAgent", title = "Agent working", tabRole = "overseer.dotTabAgent" },
}

-- Confirm strips: a destructive one is error-toned with a danger button; a
-- consequential one is accent-toned with the screen's one primary button.
local CONFIRMATIONS = {
	delete = {
		title = "Delete worktree with uncommitted changes?", confirm = "Force delete", keep = "Keep this worktree and session",
		icon = "trash", tone = "error", variant = "danger",
		detail = "Force deleting removes these changes and the directory's ignored files for good. Keeps Git branches and commits. Its session closes after successful removal. Stop file-writing tasks first.",
	},
	["remove-project"] = {
		title = "Remove project?", confirm = "Remove project", keep = "Keep this project",
		icon = "folder-minus", tone = "accent", variant = "primary",
		detail = "Stops showing this repository in Projects. Keeps the repository, its worktrees, branches and open sessions. Adding it again restores its names and Ice Box.",
	},
	["coordination-on"] = {
		title = "Turn on agent coordination", confirm = "Turn on", keep = "Not now",
		icon = "message", tone = "accent", variant = "primary", hidePath = true, subject = "Repository",
		lead = "The agents of a task and its sub-worktrees stay in touch.",
		points = {
			"The task's agent is woken when a sub-worktree's agent needs an answer, fails or opens a pull request.",
			"Sub-worktrees hear when their parent's branch moves.",
			"Agents can message each other; omp agents also see their family's news before each prompt.",
		},
		detail = "Messages only inform; nothing acts on them. Turn it off from this menu any time.",
	},
	-- A worktree with sub-worktrees: delete it alone (they move to the top
	-- level) or with them. Either way it then gets its own clean/dirty check.
	["delete-family"] = {
		title = "Delete worktree and its sub-worktrees?", confirm = "Delete only this", keep = "Keep everything",
		confirmAll = "Delete all", icon = "trash", tone = "error", variant = "default",
		detail = "Delete all also removes each sub-worktree without uncommitted changes; one with changes is kept. Kept sub-worktrees, or all of them with Delete only this, move to the top level. Branches are always kept, and this worktree still asks before losing uncommitted changes.",
	},
}

-- A folded parent's sub-worktree badge takes the tone of the agent that most needs you.
local CHILD_TONES = { waiting = "warning", failed = "error", done = "success", working = "accent" }

local function dot(key, role)
	return ui.el("div", { key = key, role = role })
end

local function basename(path)
	return path:match("([^/]+)/*$") or path
end

local function plural(n, word)
	return tostring(n) .. " " .. word .. (if n == 1 then "" else "s")
end

local function divergence(value)
	if value.ahead == 0 and value.behind == 0 then return "up to date" end
	local parts = {}
	if value.ahead > 0 then table.insert(parts, tostring(value.ahead) .. " ahead") end
	if value.behind > 0 then table.insert(parts, tostring(value.behind) .. " behind") end
	return table.concat(parts, ", ")
end

-- What a forced deletion loses, like `git status --short` with line counts:
-- the status code in amber, the path with its directory muted, the counts
-- green and red. It scrolls past a dozen lines.
local function changeList(changes)
	local rows = {}
	for index, file in ipairs(changes.files) do
		local spans = { ui.span(file.code, "warning"), " ", ui.span(file.path, "path") }
		if file.added and file.added > 0 then
			table.insert(spans, ui.span("  +" .. tostring(file.added), "success"))
		end
		if file.deleted and file.deleted > 0 then
			table.insert(spans, ui.span("  −" .. tostring(file.deleted), "error"))
		end
		table.insert(rows, ui.node("text", { key = "c" .. tostring(index), spans = spans, wrap = "none", truncate = "middle" }))
	end
	local hidden = changes.total - #changes.files
	if hidden > 0 then
		table.insert(rows, ui.node("text", { key = "more", spans = { ui.span("… and " .. tostring(hidden) .. " more", "muted") } }))
	end
	return ui.node("col", { key = "changes", role = "overseer.changes", gap = "xs" }, {
		ui.node("text", { key = "summary", spans = { ui.span(plural(changes.total, "uncommitted change"), "strong") } }),
		ui.node("scroll", { key = "list", max = { h = "12lines" } }, rows),
	})
end

-- The row's hover text: everything the minimal row leaves out. Lines without
-- anything to say are omitted.
local function details(worktree, branch)
	local lines = { branch, worktree.path, "" }
	if worktree.conflicts then table.insert(lines, "Merge conflicts: resolve them before continuing") end
	local changes = worktree.changes
	if worktree.dirty and changes then
		local kinds = {}
		for _, kind in { { "staged", "staged" }, { "modified", "edited" }, { "renamed", "renamed" },
			{ "deleted", "deleted" }, { "untracked", "new files" } } do
			if changes[kind[1]] then table.insert(kinds, kind[2]) end
		end
		local parts = {}
		if changes.added_lines and changes.deleted_lines and changes.added_lines + changes.deleted_lines > 0 then
			table.insert(parts, "+" .. tostring(changes.added_lines) .. " −" .. tostring(changes.deleted_lines))
		end
		if #kinds > 0 then table.insert(parts, table.concat(kinds, ", ")) end
		if #parts > 0 then table.insert(lines, "Uncommitted: " .. table.concat(parts, " · ")) end
	elseif not worktree.dirty then
		table.insert(lines, "No uncommitted changes")
	end
	if worktree.base then table.insert(lines, "Default branch: " .. divergence(worktree.base)) end
	if worktree.remote then
		table.insert(lines, (worktree.remote.name or "Upstream") .. ": " .. divergence(worktree.remote))
	end
	local pr = worktree.pr and PR_STATES[worktree.pr.state]
	if pr then table.insert(lines, "PR #" .. tostring(worktree.pr.number) .. " · " .. pr.label) end
	if worktree.session then
		local tabs = #(worktree.tabs or {})
		local agent = AGENT_STATUS[worktree.agent]
		table.insert(lines, "Session: " .. plural(tabs, "tab") .. (if agent then " · " .. string.lower(agent.title) else ""))
	else
		table.insert(lines, "No session · click to open")
	end
	if worktree.iced then table.insert(lines, "In the Ice Box") end
	return table.concat(lines, "\n")
end

local function statusMark(worktree)
	if worktree.iced then
		return text("status", "🧊", "overseer.iceMark", { title = "In the Ice Box" })
	elseif worktree.deleting then
		return ui.el("div", { key = "status", role = "overseer.dotDeleting", title = "Deleting" })
	elseif worktree.checking then
		return ui.el("div", { key = "status", role = "overseer.dotBusy", title = "Checking before deletion" })
	elseif worktree.creating then
		return ui.el("div", { key = "status", role = "overseer.dotCreating", title = "Creating" })
	elseif AGENT_STATUS[worktree.agent] then
		local agent = AGENT_STATUS[worktree.agent]
		return ui.el("div", { key = "status", role = agent.role, title = agent.title })
	end
	return ui.el("div", {
		key = "status", role = if worktree.session then "overseer.dotOpen" else "overseer.dotIdle",
		title = if worktree.session then "Session open" else "No session",
	})
end

-- A tab's name as the panel shows it: what the row around it already says is
-- dropped (the full name stays in the tooltip).
local function shortTabName(name)
	-- A GitHub pull request page: "<title> by <user> · Pull Request #12 · owner/repo" → "#12 <title>".
	local title, number = name:match("^(.-) by [%w%-]+ · Pull Request #(%d+) · [%w%-%.]+/[%w%-%.]+$")
	if title then return "#" .. number .. " " .. title end
	-- Any other GitHub page ends with its repository.
	local short = name:gsub(" · [%w%-%.]+/[%w%-%.]+$", "")
	-- omp ends a session title with its pull request, which the worktree row links already.
	short = short:gsub(" · #%d+$", "")
	return short
end

local function appendTabs(children, tabs)
	for _, tab in ipairs(tabs or {}) do
		local agent = AGENT_STATUS[tab.agent]
		local tabChildren = {
			dot("dot", if agent then agent.tabRole elseif tab.busy then "overseer.dotBusy" else "overseer.dotTab"),
			text("name", shortTabName(tab.name), "overseer.tabName", { grow = 1 }),
		}
		-- The dot's colour says working or waiting; a finished turn gets a badge.
		-- State labels keep their width (`basis = "content"`): a long name truncates instead.
		if agent and agent.label then
			table.insert(tabChildren, badge("state", agent.label, agent.labelTone))
		elseif not agent and tab.busy then
			table.insert(tabChildren, ui.node("text", { key = "busy", basis = "content", spans = { ui.span("Running", "warning") } }))
		end
		-- The session Overseer's messages for this worktree go to.
		if tab.lead then
			table.insert(tabChildren, badge("lead", "Overseer", "accent",
				"Overseer session: Overseer's messages for this worktree go here"))
		end
		if not tab.pane then
			table.insert(tabChildren, ui.node("text", { key = "unavailable", basis = "content", spans = { ui.span("No pane", "muted") } }))
		end
		table.insert(children, ui.node("row", {
			key = "tab" .. string.format("%d", tab.id), role = "overseer.tabRow",
			title = if tab.pane then "Focus " .. tab.name else "This tab has no focusable pane",
			actions = {
				click = if tab.pane then "tab=" .. tostring(tab.pane) else nil,
				menu = if tab.canLead then { { id = "make-lead", label = "Make overseer session", icon = "eye" } } else nil,
			},
		}, tabChildren))
	end
end

-- A session whose worktree was removed outside Overseer. Clicking still shows
-- it (an agent's last reply may be there); its only menu entry closes it.
local function goneNode(worktree, activePath)
	local summary = ui.node("col", {
		key = "row", role = "overseer.worktreeRow",
		title = worktree.label .. "\n" .. worktree.path .. "\n\nThis worktree was removed outside Overseer. Close its session from the menu.",
		aria = worktree.label .. ", worktree removed, session open",
		actions = {
			click = "open-worktree=" .. worktree.path,
			menu = { { id = "close-session", label = "Close session", icon = "x" } },
		},
	}, {
		ui.node("row", { key = "head", role = "overseer.worktreeHead" }, {
			statusMark(worktree),
			text("branch", worktree.label, "overseer.branch"),
			ui.node("row", { key = "spacer", grow = 1 }, {}),
			badge("gone", "Worktree gone", "warning"),
		}),
		text("subtitle", basename(worktree.path), "overseer.worktreeSubtitle"),
	})
	local children = { summary }
	appendTabs(children, worktree.tabs)
	return ui.node("col", {
		key = "w" .. safeKey(worktree.path), role = "overseer.worktree",
		mark = if activePath == worktree.path then "active" else nil,
	}, children)
end

local function elapsed(seconds)
	if seconds < 60 then return tostring(seconds) .. "s" end
	return string.format("%dm %02ds", seconds // 60, seconds % 60)
end

-- A creation's subtitle: how long it has run (in 5 s steps, so the row
-- redraws only that often), then what it's doing or why it may need you.
local function creatingSubtitle(state)
	local parts = { "creating", elapsed(state.elapsed // 5 * 5) }
	if state.asking then
		table.insert(parts, "asking a question in its setup tab")
	elseif state.quiet then
		table.insert(parts, "no output for " .. elapsed(state.quiet // 5 * 5))
	elseif state.step then
		table.insert(parts, state.step)
	end
	return table.concat(parts, " · ")
end

local function creatingTitle(state)
	local lines = { "Creating " .. state.label, "Running for " .. elapsed(state.elapsed) }
	if state.step then table.insert(lines, "Last: " .. state.step) end
	if state.asking then
		table.insert(lines, "")
		table.insert(lines, "It's asking a question in its setup tab, such as a hook approval.")
	elseif state.needsYou then
		table.insert(lines, "")
		table.insert(lines, "No output for a while: it may be waiting for an answer, such as a hook approval.")
	end
	table.insert(lines, "")
	table.insert(lines, "Click to open its setup tab.")
	return table.concat(lines, "\n")
end

-- The worktree's right-click menu: what it is, how it's kept, then what ends it.
local function worktreeMenu(worktree)
	if worktree.deleting or worktree.checking or worktree.creating then return {} end
	local menu = {}
	if worktree.pr then table.insert(menu, { id = "visualize", label = "Visualize PR", icon = "merge" }) end
	table.insert(menu, { id = "rename", label = "Rename…", icon = "pen" })
	if worktree.children and worktree.coordination then
		table.insert(menu, { id = "brief-children", label = "Brief sub-worktrees…", icon = "message" })
	end
	if not worktree.is_main then
		table.insert(menu, if worktree.iced
			then { id = "icebox-remove", label = "Remove from Ice Box", icon = "box" }
			else { id = "icebox-add", label = "Add to Ice Box", icon = "box" })
		if worktree.branch then
			table.insert(menu, { id = "move-under", label = "Move under…", icon = "corner-down-right" })
		end
		if worktree.parentLink then
			table.insert(menu, { id = "make-top-level", label = "Make top-level", icon = "arrow-up" })
		end
	end
	if worktree.session or not worktree.is_main then table.insert(menu, "-") end
	if worktree.session then table.insert(menu, { id = "close-session", label = "Close session", icon = "x" }) end
	if not worktree.is_main then
		table.insert(menu, { id = "delete-worktree", label = "Delete worktree", icon = "trash", danger = true })
	end
	return menu
end

local function worktreeNode(worktree, activePath)
	local branch = worktree.branch or "Detached HEAD"
	local label = worktree.displayName or branch
	local active = activePath == worktree.path
	local head = {
		statusMark(worktree),
		text("branch", label, "overseer.branch"),
	}
	-- The conflicts badge already says the worktree has unfinished changes.
	if worktree.dirty and not worktree.conflicts then
		table.insert(head, text("dirty", "✱", "overseer.dirtyMark", { title = "Uncommitted changes" }))
	end
	if worktree.is_main then
		table.insert(head, badge("primary", "Primary", "neutral"))
	end
	-- Sub-worktrees: their count, which folds them; folded, it takes the tone
	-- of the sub-worktree agent that most needs you.
	if worktree.children then
		local count = #worktree.children
		table.insert(head, ui.node("badge", {
			key = "fold", role = "overseer.fold",
			text = (if worktree.folded then "▸ " else "▾ ") .. tostring(count),
			tone = if worktree.folded then CHILD_TONES[worktree.childAgent] or "muted" else "muted",
			title = plural(count, "sub-worktree") .. (if worktree.folded then " · click to show" else " · click to fold"),
			actions = { click = "fold=" .. worktree.path },
		}))
	end
	-- Messages Overseer passed to this worktree's session since you last looked at it.
	if worktree.unread then
		table.insert(head, badge("unread", tostring(worktree.unread) .. " new", "accent",
			plural(worktree.unread, "Overseer update") .. " for this worktree's session since you last looked"))
	end
	-- Pushes the remaining badges to the row's right edge.
	table.insert(head, ui.node("row", { key = "spacer", grow = 1 }, {}))
	if worktree.conflicts then
		table.insert(head, badge("conflicts", "Conflicts", "error", "Merge conflicts"))
	end
	if worktree.creating then
		local state = worktree.creating
		table.insert(head, badge("creating", if state.needsYou then "Needs you?" else "Creating",
			if state.needsYou then "error" else "warning", creatingTitle(state)))
	elseif worktree.deleting then
		table.insert(head, badge("deleting", "Deleting", "error"))
	elseif worktree.checking then
		table.insert(head, badge("checking", "Checking", "warning"))
	elseif not worktree.session then
		table.insert(head, text("open", "Open", "overseer.openHint"))
	end
	-- The Linear ticket and pull request sit together, ticket first. They are
	-- plain icons with a click (an HTML button would take Tern's chip look).
	local links = {}
	if worktree.ticket then
		table.insert(links, ui.el("div", {
			key = "linear", role = "overseer.linear", title = worktree.ticket.id .. " — open in Linear",
			aria = "Linear ticket " .. worktree.ticket.id, actions = { click = "link=" .. worktree.ticket.url },
		}))
	end
	local pr = worktree.pr and PR_STATES[worktree.pr.state]
	if pr then
		local summary = "#" .. tostring(worktree.pr.number) .. " · " .. pr.label
		table.insert(links, ui.el("div", {
			key = "pr", role = pr.role, title = summary .. " — open on GitHub",
			aria = "Pull request " .. summary, actions = { click = "link=" .. worktree.pr.url },
		}))
	end
	if #links > 0 then
		table.insert(head, ui.node("row", { key = "links", role = "overseer.links" }, links))
	end
	-- A renamed row keeps its branch visible; otherwise the directory helps
	-- tell apart worktrees whose branch names share a long ticket prefix. The
	-- primary checkout's Primary badge already says what it is.
	local subtitle = if worktree.creating then creatingSubtitle(worktree.creating)
		elseif worktree.displayName then branch
		else basename(worktree.path)
	-- A sub-worktree also says when its session last finished a turn.
	if worktree.checkin and not worktree.creating then subtitle ..= " · checked in " .. worktree.checkin end
	local summary = ui.node("col", {
		key = "row", role = "overseer.worktreeRow",
		title = if worktree.creating then creatingTitle(worktree.creating) else details(worktree, branch),
		aria = label .. (if worktree.creating then ", creating"
				elseif AGENT_STATUS[worktree.agent] then ", " .. string.lower(AGENT_STATUS[worktree.agent].title)
				elseif worktree.session then ", session open"
				else ", open session")
			.. (if worktree.conflicts then ", merge conflicts" elseif worktree.dirty then ", uncommitted changes" else "")
			.. (if worktree.iced then ", in the Ice Box" else ""),
		actions = {
			-- While setup runs, the row leads to the setup tab, not into the worktree.
			click = if worktree.deleting then nil
				elseif worktree.creating then "tab=" .. tostring(worktree.creating.pane)
				else "open-worktree=" .. worktree.path,
			menu = worktreeMenu(worktree),
		},
	}, {
		ui.node("row", { key = "head", role = "overseer.worktreeHead" }, head),
		text("subtitle", subtitle, "overseer.worktreeSubtitle"),
	})
	local children = { summary }
	appendTabs(children, worktree.tabs)
	return ui.node("col", {
		key = "w" .. safeKey(worktree.path), role = "overseer.worktree",
		mark = if active then "active" else nil,
	}, children)
end

local function confirmationNode(request)
	local copy = CONFIRMATIONS[request.kind]
	local body = {}
	if copy.subject then
		-- "Repository: `name`": what the choice applies to, named like code.
		table.insert(body, ui.node("row", { key = "name", role = "overseer.subjectRow", gap = "xs" }, {
			ui.node("text", { key = "label", basis = "content", spans = { ui.span(copy.subject .. ":", "muted") } }),
			ui.node("text", { key = "value", role = "overseer.subject", spans = { ui.span(request.label, "mono") }, truncate = "end" }),
		}))
	else
		table.insert(body, ui.node("text", { key = "name", spans = { ui.span(request.label, "strong") } }))
	end
	if not copy.hidePath then
		table.insert(body, ui.node("text", { key = "path", spans = { ui.span(request.path, "path") }, truncate = "middle" }))
	end
	if copy.lead then table.insert(body, ui.node("text", { key = "lead", spans = { ui.span(copy.lead) } })) end
	if copy.points then
		local points = {}
		for index, point in ipairs(copy.points) do
			table.insert(points, ui.node("text", { key = "p" .. tostring(index), role = "overseer.point", spans = { ui.span(point) } }))
		end
		table.insert(body, ui.node("col", { key = "points", role = "overseer.points", gap = "xs" }, points))
	end
	if request.changes then table.insert(body, changeList(request.changes)) end
	if request.children then
		local rows = {}
		for index, child in ipairs(request.children) do
			local spans = { ui.span(child.label) }
			if child.dirty then table.insert(spans, ui.span("  ✱ uncommitted, kept", "warning")) end
			table.insert(rows, ui.node("text", { key = "s" .. tostring(index), spans = spans, wrap = "none", truncate = "end" }))
		end
		table.insert(body, ui.node("col", { key = "family", role = "overseer.family", gap = "xs" }, {
			ui.node("text", { key = "summary", spans = { ui.span(plural(#request.children, "sub-worktree"), "strong") } }),
			ui.node("scroll", { key = "list", max = { h = "12lines" } }, rows),
		}))
	end
	table.insert(body, ui.node("text", {
		key = "detail", role = if copy.points then "overseer.footnote" else nil, spans = { ui.span(copy.detail, "muted") },
	}))
	local buttons = { button("cancel", "Cancel", "cancel=" .. request.id, { variant = "quiet", title = copy.keep }) }
	table.insert(buttons, button("confirm", copy.confirm, "confirm=" .. request.id, {
		variant = copy.variant, busy = request.checking == true, title = "Confirm " .. request.label,
	}))
	if copy.confirmAll then
		table.insert(buttons, button("confirm-all", copy.confirmAll .. " " .. tostring(#request.children + 1), "confirm-all=" .. request.id, {
			variant = "danger", title = "Delete " .. request.label .. " and its sub-worktrees",
		}))
	end
	table.insert(body, ui.node("row", { key = "buttons", gap = "sm", justify = "end", wrap = true }, buttons))
	return ui.card(copy.title, body, { key = "confirmation", role = "overseer.confirmation", tone = copy.tone, icon = copy.icon })
end

local function projectNode(model, project)
	local collapsed = model.collapsed and model.collapsed[project.id]
	local menu = {
		{ id = "change-base", label = "Change base branch…", icon = "branch" },
		{ id = "set-linear", label = "Set Linear workspace…", icon = "link" },
	}
	if project.coordinationKnown then
		table.insert(menu, if project.coordination
			then { id = "coordination-off", label = "Turn off agent coordination", icon = "message" }
			else { id = "coordination-on", label = "Turn on agent coordination…", icon = "message" })
	end
	table.insert(menu, "-")
	table.insert(menu, { id = "remove-project", label = "Remove project…", icon = "folder-minus" })
	local children = {
		ui.node("row", {
			key = "header", role = "overseer.projectHeader",
			actions = { menu = menu },
		}, {
			ui.node("row", {
				key = "collapse", role = "overseer.projectToggle",
				title = (if collapsed then "Expand " else "Collapse ") .. project.name .. "\n" .. project.path,
				aria = (if collapsed then "Expand " else "Collapse ") .. project.name,
				actions = { click = "collapse=" .. project.id },
			}, {
				ui.node("icon", { key = "chev", name = if collapsed then "chev-r" else "chev" }),
				text("name", project.name, "overseer.projectName"),
			}),
			badge("count", tostring(project.total), "muted", plural(project.total, "worktree")),
			ui.node("row", { key = "spacer", grow = 1 }, {}),
			button("create", "", "create=" .. project.id, {
				icon = "plus", variant = "quiet", size = "sm", title = "New worktree from " .. project.base,
			}),
		}),
	}
	if project.error then
		table.insert(children, ui.card("Couldn't list worktrees", {
			ui.node("text", { key = "message", spans = { ui.span(project.error, "mono") }, wrap = "char" }),
			ui.node("row", { key = "buttons", justify = "end" }, {
				button("retry", "Retry", "refresh", { icon = "refresh", size = "sm" }),
			}),
		}, { key = "error", tone = "error", icon = "warn" }))
	end
	if project.loading and #(project.worktrees or {}) == 0 then
		table.insert(children, ui.node("shimmer", { key = "loading", role = "overseer.loading", text = "Loading worktrees…" }))
	end
	if not collapsed then
		for _, worktree in ipairs(project.worktrees or {}) do
			if worktree.gone then
				table.insert(children, goneNode(worktree, model.activePath))
			else
				local node = worktreeNode(worktree, model.activePath)
				-- Sub-worktrees hang under their parent's group, not inside it, so
				-- the parent's highlight and hover stay its own. The two sit in one
				-- lineage so the tree lines can run from the parent's dot to each child.
				if worktree.children and not worktree.folded then
					local nested = {}
					for _, child in ipairs(worktree.children) do
						table.insert(nested, worktreeNode(child, model.activePath))
					end
					table.insert(children, ui.node("col", { key = "t" .. safeKey(worktree.path), role = "overseer.lineage" }, {
						node,
						ui.node("col", { key = "c", role = "overseer.children" }, nested),
					}))
				else
					table.insert(children, node)
				end
			end
		end
		if not project.loading and not project.error and #(project.worktrees or {}) == 0 and project.hiddenIced == 0 then
			table.insert(children, ui.node("empty", {
				key = "empty", variant = "inline", icon = "branch", text = "No worktrees found",
			}, {
				button("refresh", "Refresh", "refresh", { variant = "quiet", size = "sm" }),
			}))
		end
	end
	return ui.node("col", { key = "p" .. safeKey(project.id), role = "overseer.project" }, children)
end

function View.render(model)
	local children = {
		ui.node("row", { key = "header", role = "overseer.header" }, {
			ui.node("text", { key = "title", role = "overseer.heading", text = "Projects" }),
			button("help", "", "help", { icon = "info", variant = "quiet", size = "sm", title = "How Projects works" }),
			ui.node("row", { key = "spacer", grow = 1 }, {}),
			ui.node("buttons", { key = "actions", variant = "toolbar", size = "sm", label = "Projects" }, {
				button("add", "", "add", { icon = "folder-plus", title = "Add an existing Git repository" }),
				button("refresh", "", "refresh", {
					icon = "refresh", busy = model.refreshing == true,
					title = if model.refreshing then "Refreshing…" else "Refresh worktrees and sessions",
				}),
				button("icebox", "🧊", "toggle-icebox", {
					on = model.showIcebox == true,
					title = if model.showIcebox then "Hide Ice Box worktrees" else "Show Ice Box worktrees",
				}),
			}),
		}),
	}
	if model.confirmation then
		table.insert(children, confirmationNode(model.confirmation))
	end
	if #model.projects == 0 then
		table.insert(children, ui.node("empty", {
			key = "empty", icon = "folder-plus", title = "Your repositories, in one place.",
			text = "Add a project to see every worktree and its Tern tabs. Existing worktrees stay as they are.",
		}, {
			button("add", "Add your first project", "add", { variant = "primary", icon = "folder-plus" }),
		}))
	end
	for _, project in ipairs(model.projects) do
		table.insert(children, projectNode(model, project))
	end
	return ui.node("col", { key = "overseer", role = "overseer.navigator" }, children)
end

return View
