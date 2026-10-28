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

-- Tern labels menu entries with the whole action string, including any =value.
-- Keep menu actions plain and recover their target from our keyed row node.
function View.worktreePath(node)
	return unhex(type(node) == "string" and node:match("%.w(%x+)%.row$") or nil)
end

function View.projectId(node)
	return unhex(type(node) == "string" and node:match("%.p(%x+)%.header$") or nil)
end

local function text(key, value, role, props)
	props = props or {}
	props.key, props.text, props.role = key, value, role
	return ui.node("text", props)
end

local function button(key, label, action, title, role)
	return ui.el("button", {
		key = key, text = label, role = role or "overseer.button",
		title = title, actions = { click = action },
	})
end

local PR_STATES = {
	draft = { role = "overseer.prDraft", label = "Draft" },
	open = { role = "overseer.prOpen", label = "Open" },
	merged = { role = "overseer.prMerged", label = "Merged" },
	closed = { role = "overseer.prClosed", label = "Closed" },
}

-- How each agent state shows: on the worktree row (a glyph badge, or a dot
-- for working) and on its tab rows (a small dot, plus a label for done and
-- failed; the yellow dot says waiting on its own).
local AGENT_STATUS = {
	waiting = {
		glyph = "?", role = "overseer.statusWaiting", title = "Agent waiting for you",
		tabRole = "overseer.dotTabWaiting",
	},
	failed = {
		glyph = "!", role = "overseer.statusFailed", title = "Agent failed",
		tabRole = "overseer.dotTabFailed", label = "failed", labelRole = "overseer.failed",
	},
	done = {
		glyph = "✔", role = "overseer.statusDone", title = "Agent finished",
		tabRole = "overseer.dotTabDone", label = "done", labelRole = "overseer.done",
	},
	working = { role = "overseer.dotAgent", title = "Agent working", tabRole = "overseer.dotTabAgent" },
}

local CONFIRMATIONS = {
	delete = {
		title = "Delete worktree?", confirm = "Delete worktree", keep = "Keep this worktree and session",
		detail = "Removes this directory, including ignored files. Keeps Git branches. Its session closes after successful removal. Stop file-writing tasks first.",
	},
	close = {
		title = "Close session?", confirm = "Close session", keep = "Keep this session",
		detail = "Stops all running programs and closes this session's tabs. Keeps the worktree files and Git branches.",
	},
	["remove-project"] = {
		title = "Remove project?", confirm = "Remove project", keep = "Keep this project",
		detail = "Stops showing this repository in Projects. Keeps the repository, its worktrees, branches and open sessions. Adding it again restores its names and Ice Box.",
	},
}

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

local function worktreeNode(worktree, activePath)
	local branch = worktree.branch or "Detached HEAD"
	local label = worktree.displayName or branch
	local active = activePath == worktree.path
	local menu = {}
	if not worktree.deleting then
		-- Menu entries show their action string verbatim, so actions are titled.
		if worktree.pr then table.insert(menu, "Visualize PR") end
		table.insert(menu, "Rename")
		if not worktree.is_main then
			table.insert(menu, if worktree.iced then "Remove from Ice Box" else "Add to Ice Box")
		end
		if worktree.session then table.insert(menu, "Close session") end
		if not worktree.is_main then table.insert(menu, "Delete worktree") end
	end
	local status
	if worktree.iced then
		status = text("status", "🧊", "overseer.iceMark", { title = "In the Ice Box" })
	elseif worktree.deleting then
		status = ui.el("div", { key = "status", role = "overseer.dotBusy", title = "Deleting" })
	elseif AGENT_STATUS[worktree.agent] then
		local agent = AGENT_STATUS[worktree.agent]
		status = if agent.glyph
			then text("status", agent.glyph, agent.role, { title = agent.title })
			else ui.el("div", { key = "status", role = agent.role, title = agent.title })
	else
		status = ui.el("div", {
			key = "status", role = if worktree.session then "overseer.dotOpen" else "overseer.dotIdle",
			title = if worktree.session then "Session open" else "No session",
		})
	end
	local head = {
		status,
		text("branch", label, "overseer.branch"),
	}
	-- The conflicts badge already says the worktree has unfinished changes.
	if worktree.dirty and not worktree.conflicts then
		table.insert(head, text("dirty", "✱", "overseer.dirtyMark", { title = "Uncommitted changes" }))
	end
	if worktree.is_main then
		table.insert(head, text("primary", "Primary", "overseer.badge"))
	end
	-- Pushes the remaining badges to the row's right edge.
	table.insert(head, ui.el("div", { key = "spacer", grow = 1 }))
	if worktree.conflicts then
		table.insert(head, text("conflicts", "conflicts", "overseer.badgeBad"))
	end
	if worktree.deleting then
		table.insert(head, text("deleting", "deleting", "overseer.badgeWarn"))
	elseif not worktree.session then
		table.insert(head, text("open", "Open", "overseer.openHint"))
	end
	-- The Linear ticket and pull request sit together, ticket first.
	local links = {}
	if worktree.ticket then
		table.insert(links, ui.el("button", {
			key = "linear", role = "overseer.linear", title = worktree.ticket.id .. " — open in Linear",
			aria = "Linear ticket " .. worktree.ticket.id, actions = { click = "link=" .. worktree.ticket.url },
		}))
	end
	local pr = worktree.pr and PR_STATES[worktree.pr.state]
	if pr then
		local summary = "#" .. tostring(worktree.pr.number) .. " · " .. pr.label
		table.insert(links, ui.el("button", {
			key = "pr", role = pr.role, title = summary .. " — open on GitHub",
			aria = "Pull request " .. summary, actions = { click = "link=" .. worktree.pr.url },
		}))
	end
	if #links > 0 then
		table.insert(head, ui.node("row", { key = "links", role = "overseer.links" }, links))
	end
	-- A renamed row keeps its branch visible; otherwise the directory helps
	-- tell apart worktrees whose branch names share a long ticket prefix.
	local subtitle = if worktree.displayName then branch
		elseif worktree.is_main then "primary checkout · " .. basename(worktree.path)
		else basename(worktree.path)
	local summary = ui.node("col", {
		key = "row", role = "overseer.worktreeRow", title = details(worktree, branch),
		aria = label .. (if AGENT_STATUS[worktree.agent] then ", " .. string.lower(AGENT_STATUS[worktree.agent].title)
				elseif worktree.session then ", session open"
				else ", open session")
			.. (if worktree.conflicts then ", merge conflicts" elseif worktree.dirty then ", uncommitted changes" else "")
			.. (if worktree.iced then ", in the Ice Box" else ""),
		actions = { click = if worktree.deleting then nil else "open-worktree=" .. worktree.path, menu = menu },
	}, {
		ui.node("row", { key = "head", role = "overseer.worktreeHead" }, head),
		text("subtitle", subtitle, "overseer.worktreeSubtitle"),
	})
	local children = { summary }
	for _, tab in ipairs(worktree.tabs or {}) do
		local agent = AGENT_STATUS[tab.agent]
		local tabChildren = {
			dot("dot", if agent then agent.tabRole elseif tab.busy then "overseer.dotBusy" else "overseer.dotTab"),
			text("name", tab.name, "overseer.tabName", { grow = 1 }),
		}
		-- The dot's colour says working or waiting; a finished turn is spelled out.
		if agent and agent.label then
			table.insert(tabChildren, text("state", agent.label, agent.labelRole))
		elseif not agent and tab.busy then
			table.insert(tabChildren, text("busy", "running", "overseer.busy"))
		end
		if not tab.pane then
			table.insert(tabChildren, text("unavailable", "no pane", "overseer.marker"))
		end
		table.insert(children, ui.node("row", {
			key = "tab" .. tostring(tab.id), role = "overseer.tabRow",
			title = if tab.pane then "Focus " .. tab.name else "This tab has no focusable pane",
			actions = if tab.pane then { click = "tab=" .. tostring(tab.pane) } else nil,
		}, tabChildren))
	end
	return ui.node("col", {
		key = "w" .. safeKey(worktree.path), role = "overseer.worktree",
		mark = if active then "pick" else nil,
	}, children)
end

function View.render(model)
	local children = {
		ui.node("row", { key = "header", role = "overseer.header" }, {
			ui.node("row", { key = "titleGroup", role = "overseer.titleGroup", grow = 1 }, {
				text("title", "Projects", "overseer.heading"),
				ui.el("button", {
					key = "help", role = "overseer.infoButton",
					title = "How Projects works", aria = "How Projects works",
					actions = { click = "help" },
				}),
			}),
			button("add", "+", "add", "Add an existing Git repository", "overseer.iconButton"),
			-- The glyph is its own element so only the arrow turns, not the button's frame.
			ui.el("button", {
				key = "refresh", role = "overseer.iconButton", actions = { click = "refresh" },
				title = if model.refreshing then "Refreshing…" else "Refresh worktrees and sessions",
				aria = if model.refreshing then "Refreshing" else "Refresh worktrees and sessions",
			}, {
				text("glyph", "↻", if model.refreshing then "overseer.refreshGlyphSpin" else "overseer.refreshGlyph"),
			}),
			button("icebox", "🧊", "toggle-icebox",
				if model.showIcebox then "Hide Ice Box worktrees" else "Show Ice Box worktrees",
				if model.showIcebox then "overseer.iconButtonOn" else "overseer.iconButton"),
		}),
	}
	if model.confirmation then
		local request = model.confirmation
		local copy = CONFIRMATIONS[request.kind]
		local buttons = {
			button("cancel", "Cancel", "cancel=" .. request.id, copy.keep),
		}
		if not request.checking then
			table.insert(buttons, button("confirm", copy.confirm,
				"confirm=" .. request.id, "Confirm " .. request.label, "overseer.dangerButton"))
		end
		table.insert(children, ui.node("col", { key = "confirmation", role = "overseer.confirmation" }, {
			text("title", copy.title, "overseer.formHeading"),
			text("name", request.label, "overseer.branch"),
			text("path", request.path, "overseer.hint"),
			text("detail", copy.detail, "overseer.hint"),
			text("status", if request.checking then "Checking worktree..." else "", "overseer.hint"),
			ui.node("row", { key = "buttons", role = "overseer.formButtons" }, buttons),
		}))
	end
	if #model.projects == 0 then
		table.insert(children, ui.node("col", { key = "empty", role = "overseer.empty" }, {
			text("title", "Your repositories, in one place.", "overseer.emptyTitle"),
			text("help", "Add a project to see every worktree and its Tern tabs. Existing worktrees stay as they are.", "overseer.hint"),
			button("add", "Add your first project", "add", "Choose a Git repository"),
		}))
	end
	for _, project in ipairs(model.projects) do
		local collapsed = model.collapsed and model.collapsed[project.id]
		local projectChildren = {
			ui.node("row", {
				key = "header", role = "overseer.projectHeader",
				actions = { menu = { "Change base branch", "Set Linear workspace", "Remove project" } },
			}, {
				button("collapse", (if collapsed then "▸  " else "▾  ") .. project.name,
					"collapse=" .. project.id, (if collapsed then "Expand " else "Collapse ") .. project.name .. "\n" .. project.path,
					"overseer.projectToggle"),
				text("count", tostring(project.total), "overseer.count"),
				button("create", "+", "create=" .. project.id, "New worktree from " .. project.base, "overseer.iconButton"),
				ui.node("row", { key = "spacer", grow = 1 }, {}),
			}),
		}
		if project.error then
			table.insert(projectChildren, text("error", project.error, "overseer.error"))
		end
		if project.loading and #(project.worktrees or {}) == 0 then
			table.insert(projectChildren, ui.node("col", { key = "loading", role = "overseer.loading" }, {
				text("label", "Loading worktrees", "overseer.shimmer", { aria = "Loading worktrees" }),
			}))
		end
		if not collapsed then
			for _, worktree in ipairs(project.worktrees or {}) do
				table.insert(projectChildren, worktreeNode(worktree, model.activePath))
			end
			if not project.loading and not project.error and #(project.worktrees or {}) == 0 and project.hiddenIced == 0 then
				table.insert(projectChildren, text("empty", "No worktrees found. Refresh to check this repository.", "overseer.hint"))
			end
		end
		table.insert(children, ui.node("col", {
			key = "p" .. safeKey(project.id), role = "overseer.project",
		}, projectChildren))
	end
	return ui.node("col", { key = "overseer", role = "overseer.navigator" }, children)
end

return View
