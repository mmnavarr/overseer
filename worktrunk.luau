-- Read-only discovery uses argv subprocesses; creation and removal run in a terminal.
local M = {}
local TIMEOUT_MS = 15000

local function deferred_error(done, message)
	tern.timer(0, function(cx)
		done(nil, message, cx)
	end)
end

local function run(argv, done, cwd)
	local ok, err = pcall(function()
		tern.process.run(argv, { timeout_ms = TIMEOUT_MS, cwd = cwd }, function(result, cx)
			if result.timed_out then
				done(nil, "Command timed out after 15 seconds: " .. argv[1], cx)
			else
				done(result, nil, cx)
			end
		end)
	end)
	if not ok then
		deferred_error(done, "Could not start " .. argv[1] .. ": " .. tostring(err))
	end
end

local function output_line(text)
	-- Remove only Git's final record delimiter, never whitespace in a path.
	return (string.gsub(text, "\n$", ""))
end

local function command_error(label, result)
	local detail = output_line(result.stderr)
	if detail == "" then
		detail = "exit status " .. tostring(result.status)
	end
	return label .. ": " .. detail
end

local function git(path, args, done)
	local argv = { "git", "--no-optional-locks", "-C", path }
	for _, arg in ipairs(args) do
		table.insert(argv, arg)
	end
	run(argv, done)
end

local function find_executable(name)
	-- Match executable-name lookup without invoking the user's shell or its hooks.
	local path = tern.getenv("PATH") or ""
	for directory in string.gmatch(path .. ":", "(.-):") do
		if string.sub(directory, 1, 1) == "/" then
			local candidate = directory .. "/" .. name
			if tern.fs.exists(candidate) then
				return candidate
			end
		end
	end
	local home = tern.getenv("HOME") or ""
	for _, candidate in ipairs({
		"/opt/homebrew/bin/" .. name, "/usr/local/bin/" .. name,
		home .. "/.bun/bin/" .. name, home .. "/.local/bin/" .. name,
	}) do
		if tern.fs.exists(candidate) then
			return candidate
		end
	end
	return nil
end

local function resolve_wt()
	return find_executable("wt")
		or error("Worktrunk (wt) was not found. Install it and make wt available on Tern's PATH.", 0)
end

local function primary_checkout(porcelain)
	local path = nil
	local bare = false
	for field in string.gmatch(porcelain, "([^\0]*)\0") do
		if field == "" then
			if path and not bare then
				return path
			end
			path = nil
			bare = false
		elseif string.sub(field, 1, 9) == "worktree " then
			path = string.sub(field, 10)
		elseif field == "bare" then
			bare = true
		end
	end
	return nil
end

local function discover_base(project, done)
	git(project.path, { "for-each-ref", "--format=%(refname)", "refs/heads/" }, function(result, err, cx)
		if not result then
			done(nil, err, cx)
			return
		end
		if result.status ~= 0 then
			done(nil, command_error("Cannot read local branches", result), cx)
			return
		end
		local branches = {}
		for ref in string.gmatch(result.stdout, "([^\n]+)\n") do
			branches[ref] = true
		end
		if branches["refs/heads/master"] then
			project.base = "master"
			done(project, nil, cx)
			return
		end
		git(project.path, { "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD" }, function(head, head_err, next_cx)
			if not head then
				done(nil, head_err, next_cx)
				return
			end
			local default = if head.status == 0 then string.match(output_line(head.stdout), "^refs/remotes/origin/(.+)$") else nil
			if default and branches["refs/heads/" .. default] then
				project.base = default
			elseif branches["refs/heads/main"] then
				project.base = "main"
			else
				-- Nothing conventional: use the primary checkout's current branch.
				git(project.path, { "symbolic-ref", "--quiet", "--short", "HEAD" }, function(current, current_err, current_cx)
					if not current then
						done(nil, current_err, current_cx)
						return
					end
					project.base = if current.status == 0 then output_line(current.stdout) else ""
					done(project, nil, current_cx)
				end)
				return
			end
			done(project, nil, next_cx)
		end)
	end)
end

-- Inspects a folder chosen in the picker. done(project, err, cx, notRepo):
-- notRepo is true when the folder isn't inside a Git checkout at all.
function M.inspect(path, done)
	if type(path) ~= "string" or string.sub(path, 1, 1) ~= "/" or string.find(path, "\0", 1, true) then
		deferred_error(done, "The folder picker returned an unexpected path.")
		return
	end
	git(path, { "rev-parse", "--path-format=absolute", "--git-common-dir" }, function(common, err, cx)
		if not common then
			done(nil, err, cx)
			return
		end
		if common.status ~= 0 then
			if string.find(common.stderr or "", "not a git repository", 1, true) then
				done(nil, "Choose a repository folder.", cx, true)
			else
				done(nil, command_error("Cannot open Git repository", common), cx)
			end
			return
		end
		local common_dir = output_line(common.stdout)
		if string.sub(common_dir, 1, 1) ~= "/" then
			done(nil, "Git did not return an absolute common directory. Update Git and try again.", cx)
			return
		end
		-- pwd -P resolves symlinks in a separate process without changing Tern's cwd.
		run({ "/bin/pwd", "-P" }, function(physical, physical_err, physical_cx)
			if not physical then
				done(nil, physical_err, physical_cx)
				return
			end
			if physical.status ~= 0 then
				done(nil, command_error("Cannot resolve Git common directory", physical), physical_cx)
				return
			end
			local id = output_line(physical.stdout)
			git(path, { "worktree", "list", "--porcelain", "-z" }, function(trees, trees_err, trees_cx)
				if not trees then
					done(nil, trees_err, trees_cx)
					return
				end
				if trees.status ~= 0 then
					done(nil, command_error("Cannot discover worktrees", trees), trees_cx)
					return
				end
				local primary = primary_checkout(trees.stdout)
				if not primary then
					done(nil, "This bare repository has no checkout. Add a Git worktree before adding this project.", trees_cx)
					return
				end
				git(primary, { "rev-parse", "--show-toplevel" }, function(top, top_err, top_cx)
					if not top then
						done(nil, top_err, top_cx)
						return
					end
					if top.status ~= 0 then
						done(nil, command_error("The primary checkout is unavailable", top), top_cx)
						return
					end
					local checkout = output_line(top.stdout)
					discover_base({ id = id, name = string.match(checkout, "([^/]+)$") or checkout, path = checkout, base = "" }, done)
				end)
			end)
		end, common_dir)
	end)
end

local function require_array(value, label)
	if type(value) ~= "table" then
		error(label .. " must be a JSON array", 0)
	end
	if #value == 0 and tern.json.encode(value) ~= "[]" then
		error(label .. " must be a JSON array, not an object", 0)
	end
	local count = 0
	for key in pairs(value) do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
			error(label .. " must be a JSON array", 0)
		end
		count += 1
	end
	if count ~= #value then
		error(label .. " contains missing array entries", 0)
	end
end

-- Optional display details: absent or malformed values are dropped, not errors.
local function count(value)
	return if type(value) == "number" and value >= 0 then value else nil
end

local function divergence(value)
	if type(value) ~= "table" then return nil end
	local ahead, behind = count(value.ahead), count(value.behind)
	if not ahead or not behind then return nil end
	return { ahead = ahead, behind = behind, name = if type(value.name) == "string" then value.name else nil }
end

local function parse_worktrees(text, project)
	local value = tern.json.decode(text)
	local schema2 = type(value) == "table" and value.schema ~= nil
	local items = value
	if schema2 then
		if value.schema ~= 2 then
			error("Unsupported Worktrunk JSON schema: " .. tostring(value.schema), 0)
		end
		items = value.items
	end
	require_array(items, "Worktrunk listing")
	local trees = {}
	for index, row in ipairs(items) do
		if type(row) ~= "table" then
			error("Worktrunk row " .. tostring(index) .. " must be an object", 0)
		end
		if (schema2 and row.worktree ~= nil) or (not schema2 and row.kind == "worktree") then
			local facts = row.worktree
			local path = if schema2 then (if type(facts) == "table" then facts.path else nil) else row.path
			local main = if schema2 then (if type(facts) == "table" then facts.main else nil) else row.is_main
			local detached = if type(facts) == "table" then facts.detached else nil
			local changes = if schema2 then (if type(facts) == "table" then facts.changes else nil) else row.working_tree
			if type(path) ~= "string" or string.sub(path, 1, 1) ~= "/" or string.find(path, "\0", 1, true) then
				error("Worktrunk returned a worktree without a valid absolute path", 0)
			end
			if type(main) ~= "boolean" or type(detached) ~= "boolean" then
				error("Worktrunk returned invalid main/detached flags for " .. path, 0)
			end
			if row.branch ~= nil and type(row.branch) ~= "string" then
				error("Worktrunk returned an invalid branch for " .. path, 0)
			end
			if not detached and (row.branch == nil or row.branch == "") then
				error("Worktrunk omitted the branch for " .. path, 0)
			end
			if type(changes) ~= "table" then
				error("Worktrunk could not determine working-tree status for " .. path .. ". Refresh to try again.", 0)
			end
			local conflicts = row.operation_state == "conflicts"
			local dirty = conflicts
			for _, flag in ipairs({ "staged", "modified", "untracked", "renamed", "deleted" }) do
				if type(changes[flag]) ~= "boolean" then
					error("Worktrunk returned incomplete working-tree status for " .. path, 0)
				end
				dirty = dirty or changes[flag]
			end
			if changes.conflicted ~= nil and type(changes.conflicted) ~= "boolean" then
				error("Worktrunk returned an invalid conflict flag for " .. path, 0)
			end
			conflicts = conflicts or changes.conflicted == true
			dirty = dirty or conflicts
			local diff = type(changes.diff) == "table" and changes.diff or {}
			table.insert(trees, {
				path = path, branch = if detached then nil else row.branch, is_main = main or path == project.path,
				dirty = dirty, conflicts = conflicts,
				changes = {
					staged = changes.staged, modified = changes.modified, untracked = changes.untracked,
					renamed = changes.renamed, deleted = changes.deleted,
					added_lines = count(diff.added), deleted_lines = count(diff.deleted),
				},
				-- Commits ahead/behind the default branch and the upstream.
				base = divergence(row.main), remote = divergence(row.remote),
			})
		elseif not schema2 and type(row.kind) ~= "string" then
			error("Worktrunk returned a row without a kind", 0)
		end
	end
	table.sort(trees, function(a, b)
		if a.is_main ~= b.is_main then
			return a.is_main
		end
		local left = a.branch or a.path
		local right = b.branch or b.path
		return if left == right then a.path < b.path else left < right
	end)
	return trees
end

function M.list(project, done)
	local ok, wt = pcall(resolve_wt)
	if not ok then
		deferred_error(done, tostring(wt))
		return
	end
	run({ wt, "-C", project.path, "list", "--format=json" }, function(result, err, cx)
		if not result then
			done(nil, err, cx)
		elseif result.status ~= 0 then
			done(nil, command_error("Cannot list worktrees", result), cx)
		else
			local parsed, trees = pcall(parse_worktrees, result.stdout, project)
			if parsed then
				done(trees, nil, cx)
			else
				done(nil, "Cannot read Worktrunk JSON: " .. tostring(trees), cx)
			end
		end
	end)
end

local function branch_error(branch)
	if type(branch) ~= "string" or branch == "" then
		return "Enter a new branch name."
	end
	if string.sub(branch, 1, 1) == "-" or string.find(branch, "[%c]") or string.find(branch, "@{-", 1, true) then
		return "Use a literal branch name without a leading dash, control characters, or @{-n} expansion."
	end
	return nil
end

function M.validate(project, branch, done)
	local invalid = branch_error(branch)
	if invalid then
		deferred_error(done, invalid)
		return
	end
	git(project.path, { "check-ref-format", "--branch", branch }, function(result, err, cx)
		if not result then
			done(nil, err, cx)
			return
		end
		if result.status ~= 0 then
			done(nil, command_error("Invalid branch name", result), cx)
			return
		end
		git(project.path, { "show-ref", "--verify", "--quiet", "refs/heads/" .. project.base }, function(base, base_err, base_cx)
			if not base then
				done(nil, base_err, base_cx)
				return
			end
			if base.status ~= 0 then
				done(nil, "Local base branch '" .. project.base .. "' is unavailable. Restore it or re-add the project.", base_cx)
				return
			end
			git(project.path, { "show-ref", "--verify", "--quiet", "refs/heads/" .. branch }, function(existing, existing_err, existing_cx)
				if not existing then
					done(nil, existing_err, existing_cx)
				elseif existing.status == 0 then
					done(nil, "Branch '" .. branch .. "' already exists. Choose a new branch name.", existing_cx)
				elseif existing.status == 1 then
					done(true, nil, existing_cx)
				else
					done(nil, command_error("Cannot check existing branches", existing), existing_cx)
				end
			end)
		end)
	end)
end

function M.validate_removal(project, worktree, done)
	M.list(project, function(trees, err, cx)
		if not trees then done(nil, err, cx); return end
		for _, current in trees do
			if current.path == worktree.path then
				if current.is_main or current.path == project.path then
					done(nil, "The primary checkout cannot be deleted.", cx)
				elseif current.dirty then
					done(nil, "Commit, stash, or move changes first.", cx)
				elseif current.branch ~= worktree.branch then
					done(nil, "Branch changed. Refresh Projects.", cx)
				else
					done(current, nil, cx)
				end
				return
			end
		end
		done(nil, "Worktree not found. Refresh Projects.", cx)
	end)
end

local function octal_bytes(value)
	if type(value) ~= "string" or string.find(value, "\0", 1, true) then
		error("Worktrunk arguments must be strings without NUL bytes", 0)
	end
	return (string.gsub(value, ".", function(byte)
		return string.format("\\0%03o", string.byte(byte))
	end))
end

local function operation_command(mode, project, target, option, receipt)
	if type(receipt) ~= "string" or string.sub(receipt, 1, 1) ~= "/" then
		error("The operation receipt must have an absolute path", 0)
	end
	local args = { tern.plugin.dir .. "/worktree-operation.sh", mode, resolve_wt(), project.path, target, option, receipt }
	local program = {}
	-- macOS Bash 3.2's printf -v can reuse the previous value for an empty
	-- %b result. A prefix makes every assignment nonempty; strip it afterward.
	for index, value in ipairs(args) do
		local variable = "a" .. tostring(index)
		table.insert(program, 'printf -v ' .. variable .. ' "_%b" "' .. octal_bytes(value) .. '"; '
			.. variable .. '=${' .. variable .. '#_}; ')
	end
	table.insert(program, 'exec /bin/bash "$a1" "$a2" "$a3" "$a4" "$a5" "$a6" "$a7"')
	-- A single-quoted ASCII payload, with no apostrophes, is literal in sh/zsh,
	-- fish and Nushell. All decoding happens in Bash, not the user's login shell.
	return "/bin/bash -c '" .. table.concat(program) .. "'"
end

function M.creation_command(project, branch, receipt)
	local invalid = branch_error(branch)
	if invalid then error(invalid, 0) end
	return operation_command("create", project, branch, project.base, receipt)
end

function M.removal_command(project, worktree, receipt)
	if worktree.is_main or worktree.path == project.path then
		error("The primary checkout cannot be deleted.", 0)
	end
	return operation_command("remove", project, worktree.path, worktree.branch or "", receipt)
end

-- "git@github.com:owner/repo.git", "https://github.com/owner/repo", "ssh://git@github.com/owner/repo.git"
local function github_repo(url)
	local owner, name = string.match(url, "github%.com[:/]([^/]+)/([^/]+)$")
	if not owner then return nil end
	name = string.gsub(name, "%.git$", "")
	return owner, name
end

local PR_FIELDS = "nodes { ... on PullRequest { number state isDraft url updatedAt headRefName } }"

-- Several PRs can share a head branch (reopened, recreated). Prefer an open
-- one; otherwise the most recently updated. GitHub's `head:` search can also
-- match by prefix, so require an exact branch name.
local function pick_pr(nodes, branch)
	local best
	for _, pr in nodes or {} do
		if type(pr) == "table" and pr.headRefName == branch and type(pr.number) == "number" then
			local open = pr.state == "OPEN"
			local best_open = best and best.state == "OPEN"
			if not best or (open and not best_open) or (open == best_open and (pr.updatedAt or "") > (best.updatedAt or "")) then
				best = pr
			end
		end
	end
	if not best then return nil end
	local state = if best.state == "MERGED" then "merged"
		elseif best.state == "CLOSED" then "closed"
		elseif best.isDraft then "draft"
		else "open"
	return { number = best.number, state = state, url = best.url }
end

-- Looks up the pull request for each branch with one GitHub GraphQL request,
-- through the user's authenticated `gh`. Matches by head branch name, so PRs
-- whose branch was deleted after merging are still found.
-- done(map of branch -> { number, state = draft|open|merged|closed, url }, err, cx)
-- An empty map means "nothing to show" (no branches or not a GitHub repository).
function M.pull_requests(project, branches, done)
	local gh = find_executable("gh")
	if not gh then
		deferred_error(done, "GitHub CLI (gh) was not found")
		return
	end
	git(project.path, { "remote", "get-url", "origin" }, function(remote, err, cx)
		if not remote then done(nil, err, cx); return end
		local owner, name = github_repo(output_line(remote.stdout))
		if remote.status ~= 0 or not owner or #branches == 0 then done({}, nil, cx); return end
		local declarations, fields = {}, {}
		local argv = { gh, "api", "graphql" }
		for index, branch in ipairs(branches) do
			-- Search strings travel as GraphQL variables: branch names need no escaping.
			table.insert(declarations, "$q" .. index .. ": String!")
			table.insert(fields, "b" .. index .. ": search(query: $q" .. index .. ", type: ISSUE, first: 10) { " .. PR_FIELDS .. " }")
			table.insert(argv, "-f")
			table.insert(argv, "q" .. index .. "=repo:" .. owner .. "/" .. name .. " is:pr head:" .. branch)
		end
		table.insert(argv, "-f")
		table.insert(argv, "query=query(" .. table.concat(declarations, ", ") .. ") { " .. table.concat(fields, " ") .. " }")
		run(argv, function(result, run_err, next_cx)
			if not result then done(nil, run_err, next_cx); return end
			if result.status ~= 0 then done(nil, command_error("GitHub lookup failed", result), next_cx); return end
			local ok, value = pcall(tern.json.decode, result.stdout)
			if not ok or type(value) ~= "table" or type(value.data) ~= "table" then
				done(nil, "GitHub returned an unexpected response", next_cx)
				return
			end
			local found = {}
			for index, branch in ipairs(branches) do
				local hits = value.data["b" .. index]
				found[branch] = pick_pr(type(hits) == "table" and hits.nodes or nil, branch)
			end
			done(found, nil, next_cx)
		end)
	end)
end

M.find_executable = find_executable

local SNAPSHOT_FIELDS = "number,title,body,url,state,baseRefName,headRefName,headRefOid,author,files"

-- Reads one pull request's metadata straight from GitHub (so merged PRs whose
-- branch was deleted still work). Read-only. done(meta with .repo = "owner/name", err, cx)
function M.pull_request_meta(project, number, done)
	local gh = find_executable("gh")
	if not gh then
		deferred_error(done, "GitHub CLI (gh) was not found")
		return
	end
	git(project.path, { "remote", "get-url", "origin" }, function(remote, err, cx)
		if not remote then done(nil, err, cx); return end
		local owner, name = github_repo(output_line(remote.stdout))
		if remote.status ~= 0 or not owner then done(nil, "origin is not a GitHub repository", cx); return end
		local repo = owner .. "/" .. name
		run({ gh, "pr", "view", tostring(number), "--repo", repo, "--json", SNAPSHOT_FIELDS }, function(result, run_err, next_cx)
			if not result then done(nil, run_err, next_cx); return end
			if result.status ~= 0 then done(nil, command_error("GitHub lookup failed", result), next_cx); return end
			local ok, meta = pcall(tern.json.decode, result.stdout)
			if not ok or type(meta) ~= "table" or type(meta.title) ~= "string" then
				done(nil, "GitHub returned an unexpected response", next_cx)
				return
			end
			meta.repo = repo
			done(meta, nil, next_cx)
		end)
	end)
end

-- Writes the pull request's complete diff to `path` without passing it through
-- Lua, which a large diff would make slow. Read-only. done(true, err, cx)
function M.pull_request_diff(repo, number, path, done)
	local gh = find_executable("gh")
	if not gh then
		deferred_error(done, "GitHub CLI (gh) was not found")
		return
	end
	-- Arguments arrive as $0..$3, never as shell text.
	run({ "/bin/bash", "-c", '"$0" pr diff "$1" --repo "$2" > "$3"', gh, tostring(number), repo, path }, function(result, err, cx)
		if not result then done(nil, err, cx); return end
		if result.status ~= 0 then done(nil, command_error("GitHub diff failed", result), cx); return end
		done(true, nil, cx)
	end)
end

-- The workspace the Linear CLI (`linear`) is signed in to, so ticket links work
-- without asking. done(slug, err, cx); slug is nil when it can't be found.
function M.linear_workspace(done)
	local linear = find_executable("linear")
	if not linear then
		deferred_error(done, "Linear CLI (linear) was not found")
		return
	end
	run({ linear, "auth", "whoami" }, function(result, err, cx)
		if not result then done(nil, err, cx); return end
		if result.status ~= 0 then done(nil, command_error("Linear CLI lookup failed", result), cx); return end
		local slug = string.match(result.stdout, "Slug:%s*([%w%-]+)")
		if not slug then done(nil, "Linear CLI reported no workspace", cx); return end
		done(string.lower(slug), nil, cx)
	end)
end

return M
