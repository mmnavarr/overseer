// Usage for Overseer Settings: what omp's sessions cost, by project and worktree.
//
//   BUN_BE_BUN=1 omp usage.ts PROJECTS_JSON [SESSIONS_DIR]
//
// omp is a compiled Bun program, and BUN_BE_BUN=1 makes it run this file as Bun
// would, so Usage needs nothing omp doesn't bring. PROJECTS_JSON is Overseer's
// projects, [{name, path, id}], where id is the repository's shared Git
// directory. SESSIONS_DIR defaults to omp's, ~/.omp/agent/sessions. Prints one
// JSON object with the Today, 7 days (today and the six days before) and 30 days
// ranges. Prices are omp's per-reply estimates.
import { existsSync, readdirSync, readFileSync, realpathSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, relative, sep } from "node:path";

export type Project = { name?: string; path: string; id?: string };
type RangeKey = "today" | "week" | "month";
type Place = [project: string, worktree: string];
type Fields = Record<string, unknown>;

const RANGES: [RangeKey, number][] = [["today", 1], ["week", 7], ["month", 30]];
const OTHER = "Other";
const PRIMARY = "Primary checkout";
const DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

// Session lines are omp's JSON, read field by field: anything missing or of
// another type reads as absent.
function fields(value: unknown): Fields {
	return value && typeof value === "object" ? (value as Fields) : {};
}

function text(value: unknown): string | undefined {
	return typeof value === "string" ? value : undefined;
}

function real(path: string): string {
	try {
		return realpathSync(path);
	} catch {
		return path;
	}
}

function read(path: string): string | undefined {
	try {
		return readFileSync(path, "utf8");
	} catch {
		return undefined;
	}
}

/** The checkout holding `path` and its shared Git directory. */
function gitRoot(path: string): [root: string, common: string] | undefined {
	for (; path && path !== "/"; path = dirname(path)) {
		const dotGit = join(path, ".git");
		if (!existsSync(dotGit)) continue;
		if (statSync(dotGit).isDirectory()) return [path, real(dotGit)];
		const match = /^gitdir:\s*(.+?)\s*$/m.exec(read(dotGit) ?? "");
		if (!match) return undefined;
		const gitdir = isAbsolute(match[1]) ? match[1] : join(path, match[1]);
		const common = read(join(gitdir, "commondir"))?.trim();
		return [path, real(common ? join(gitdir, common) : dirname(dirname(gitdir)))];
	}
	return undefined;
}

/** Maps a session's folder to its project and worktree. */
export class Places {
	private projects: { name: string; path: string; id: string }[];
	private known = new Map<string, Place>();

	constructor(projects: Project[]) {
		this.projects = projects
			.filter(project => project.path)
			.map(project => ({
				name: project.name || basename(project.path),
				path: real(project.path),
				id: project.id ? real(project.id) : "",
			}));
	}

	of(cwd: string | undefined): Place {
		const key = cwd ?? "";
		let place = this.known.get(key);
		if (!place) {
			place = this.find(cwd ? real(cwd) : "");
			this.known.set(key, place);
		}
		return place;
	}

	private find(cwd: string): Place {
		if (!cwd) return [OTHER, "unknown folder"];
		const found = gitRoot(cwd);
		if (found) {
			for (const project of this.projects) {
				if (found[1] !== project.id) continue;
				return [project.name, found[0] === project.path ? PRIMARY : label(project.path, found[0])];
			}
		}
		for (const project of this.projects) {
			if (cwd === project.path || cwd.startsWith(project.path + "/")) return [project.name, PRIMARY];
		}
		// A worktree removed since: Worktrunk puts them beside the repository, named <repo>.<branch>.
		for (let path = cwd; path && path !== "/"; path = dirname(path)) {
			for (const project of this.projects) {
				if (dirname(path) === dirname(project.path) && basename(path).startsWith(basename(project.path) + ".")) {
					return [project.name, label(project.path, path)];
				}
			}
		}
		return [OTHER, (found?.[0] ?? cwd).replace(homedir(), "~")];
	}
}

function label(repository: string, root: string): string {
	const name = basename(root);
	const prefix = basename(repository) + ".";
	return name.startsWith(prefix) ? name.slice(prefix.length) : name;
}

/** omp prefixes titles with an icon from a private-use font. */
function clean(title: string | undefined): string {
	return [...(title ?? "")]
		.filter(ch => {
			const code = ch.codePointAt(0) ?? 0;
			return !((code >= 0xe000 && code <= 0xf8ff) || code >= 0xf0000);
		})
		.join("")
		.trim();
}

function dayKey(date: Date): string {
	return `${date.getFullYear()}-${date.getMonth()}-${date.getDate()}`;
}

function round(value: number): number {
	return Math.round(value * 100) / 100;
}

type Buckets = Map<number, number>;

function add(buckets: Buckets, bucket: number, cost: number) {
	buckets.set(bucket, (buckets.get(bucket) ?? 0) + cost);
}

export function summarize(projects: Project[], root: string, now = new Date()) {
	const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
	const starts = new Map<RangeKey, Date>();
	const dayIndex = new Map<RangeKey, Map<string, number>>();
	for (const [key, days] of RANGES) {
		const start = new Date(today.getFullYear(), today.getMonth(), today.getDate() - (days - 1));
		starts.set(key, start);
		const index = new Map<string, number>();
		for (let day = 0; day < days; day++) {
			index.set(dayKey(new Date(start.getFullYear(), start.getMonth(), start.getDate() + day)), day);
		}
		dayIndex.set(key, index);
	}
	const oldest = starts.get("month")!.getTime();
	const places = new Places(projects);

	const totals = new Map(RANGES.map(([key]) => [key, { cost: 0, replies: 0, tokens: 0, cacheReads: 0, subagents: 0, sessions: new Set<string>() }]));
	// "<range>\0<project>\0<worktree>" -> bucket -> cost; a bucket is an hour today, else a day index.
	const spend = new Map<string, Buckets>();
	const sessions = new Map<string, Set<string>>();
	const models = new Map<string, number>();
	const bySession = new Map<string, number>();
	const titles = new Map<string, [string | undefined, Place]>();

	let files: string[] = [];
	try {
		files = (readdirSync(root, { recursive: true }) as string[]).filter(file => file.endsWith(".jsonl"));
	} catch {}
	for (const file of files) {
		const path = join(root, file);
		let content: string;
		try {
			if (statSync(path).mtimeMs < oldest) continue;
			content = readFileSync(path, "utf8");
		} catch {
			continue;
		}
		// A subagent's session sits in a folder inside its parent session's.
		const subagent = relative(root, path).split(sep).length > 2;
		let cwd: string | undefined;
		let title: string | undefined;
		let model: string | undefined;
		for (const line of content.split("\n")) {
			if (!line.includes('"cost"') && !line.includes('"session"') && !line.includes('"title"') && !line.includes('"model')) continue;
			let parsed: unknown;
			try {
				parsed = JSON.parse(line);
			} catch {
				continue;
			}
			const entry = fields(parsed);
			const message = fields(entry.message);
			let usage: Fields;
			if (entry.type === "session") {
				cwd ??= text(entry.cwd);
				title ??= text(entry.title);
				continue;
			} else if (entry.type === "title") {
				title = text(entry.title) || title;
				continue;
			} else if (entry.type === "model_change") {
				model = text(entry.model) || model;
				continue;
			} else if (entry.type === "message") {
				usage = fields(message.usage);
				model = text(message.model) || model;
			} else if (entry.type === "model_usage") {
				usage = fields(entry.usage);
			} else {
				continue;
			}
			const cost = Number(fields(usage.cost).total) || 0;
			if (!cost) continue;
			const at = new Date(text(entry.timestamp) ?? text(message.timestamp) ?? NaN);
			if (Number.isNaN(at.getTime()) || at.getTime() < oldest) continue;
			const place = places.of(cwd);
			const name = (model ?? "unknown").split("/").pop()!;
			for (const [key] of RANGES) {
				if (at < starts.get(key)!) continue;
				const total = totals.get(key)!;
				total.cost += cost;
				total.tokens += Number(usage.totalTokens) || 0;
				total.cacheReads += Number(usage.cacheRead) || 0;
				if (entry.type === "message") total.replies++;
				const where = `${key}\0${place[0]}\0${place[1]}`;
				if (subagent) {
					total.subagents += cost;
				} else {
					total.sessions.add(path);
					if (!sessions.has(where)) sessions.set(where, new Set());
					sessions.get(where)!.add(path);
					bySession.set(`${key}\0${path}`, (bySession.get(`${key}\0${path}`) ?? 0) + cost);
					titles.set(path, [title, place]);
				}
				const bucket = key === "today" ? at.getHours() : dayIndex.get(key)!.get(dayKey(at)) ?? 0;
				if (!spend.has(where)) spend.set(where, new Map());
				add(spend.get(where)!, bucket, cost);
				models.set(`${key}\0${name}`, (models.get(`${key}\0${name}`) ?? 0) + cost);
			}
		}
	}

	const series = (buckets: Buckets, key: RangeKey) => {
		const count = key === "today" ? now.getHours() + 1 : RANGES.find(([range]) => range === key)![1];
		return Array.from({ length: count }, (_, index) => round(buckets.get(index) ?? 0));
	};
	const pad = (n: number) => String(n).padStart(2, "0");

	const ranges: Record<string, unknown> = {};
	for (const [key, days] of RANGES) {
		const start = starts.get(key)!;
		type Repo = { name: string; cost: number; sessions: Set<string> | number; buckets?: Buckets; spark?: number[]; worktrees: { name: string; cost: number; sessions: number; spark: number[] }[] };
		const repos = new Map<string, Repo>();
		const all: Buckets = new Map();
		for (const [where, buckets] of spend) {
			const [rangeKey, project, worktree] = where.split("\0");
			if (rangeKey !== key) continue;
			let repo = repos.get(project);
			if (!repo) {
				repo = { name: project, cost: 0, sessions: new Set(), buckets: new Map(), worktrees: [] };
				repos.set(project, repo);
			}
			let cost = 0;
			for (const [bucket, value] of buckets) {
				cost += value;
				add(repo.buckets!, bucket, value);
				add(all, bucket, value);
			}
			repo.cost += cost;
			for (const path of sessions.get(where) ?? []) (repo.sessions as Set<string>).add(path);
			repo.worktrees.push({ name: worktree, cost: round(cost), sessions: sessions.get(where)?.size ?? 0, spark: series(buckets, key) });
		}
		const ordered = [...repos.values()].sort((a, b) => Number(a.name === OTHER) - Number(b.name === OTHER) || b.cost - a.cost);
		for (const repo of ordered) {
			repo.worktrees.sort((a, b) => b.cost - a.cost);
			repo.cost = round(repo.cost);
			repo.sessions = (repo.sessions as Set<string>).size;
			repo.spark = series(repo.buckets!, key);
			delete repo.buckets;
		}
		const top = [...bySession]
			.filter(([id]) => id.startsWith(key + "\0"))
			.map(([id, cost]) => [id.slice(key.length + 1), cost] as const)
			.sort((a, b) => b[1] - a[1])
			.slice(0, 8)
			.map(([path, cost]) => {
				const [title, place] = titles.get(path)!;
				return { title: clean(title) || basename(path), project: place[0], worktree: place[1], cost: round(cost) };
			});
		const labels = key === "today"
			? Array.from({ length: now.getHours() + 1 }, (_, hour) => `${pad(hour)}:00`)
			: Array.from({ length: days }, (_, day) => {
				const date = new Date(start.getFullYear(), start.getMonth(), start.getDate() + day);
				return `${DAYS[date.getDay()].slice(0, 3)} ${date.getDate()} ${MONTHS[date.getMonth()]}`;
			});
		const total = totals.get(key)!;
		ranges[key] = {
			since: key === "today" ? "Since midnight" : `Since ${DAYS[start.getDay()]} ${start.getDate()} ${MONTHS[start.getMonth()]}`,
			labels,
			cost: round(total.cost),
			replies: total.replies,
			tokens: total.tokens,
			cacheReads: total.cacheReads,
			subagents: round(total.subagents),
			sessions: total.sessions.size,
			series: series(all, key),
			repos: ordered,
			models: [...models]
				.filter(([id]) => id.startsWith(key + "\0"))
				.sort((a, b) => b[1] - a[1])
				.map(([id, cost]) => ({ name: id.slice(key.length + 1), cost: round(cost) })),
			top,
		};
	}
	return { read: `${pad(now.getHours())}:${pad(now.getMinutes())}`, ranges };
}

if (import.meta.main) {
	const projects = JSON.parse(process.argv[2] ?? "[]") as Project[];
	const root = process.argv[3] ?? join(homedir(), ".omp", "agent", "sessions");
	console.log(JSON.stringify(summarize(projects, root)));
}
