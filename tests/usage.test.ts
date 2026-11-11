// Run with omp's Bun: BUN_BE_BUN=1 omp test tests/usage.test.ts
import { afterAll, beforeAll, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { summarize } from "../usage.ts";

const now = new Date();
const day = (offset: number, hour: number, minute = 0) =>
	new Date(now.getFullYear(), now.getMonth(), now.getDate() + offset, hour, minute).toISOString();

let base = "";
let sessions = "";
let repo = "";

function session(file: string, cwd: string, replies: [at: string, cost: number][]) {
	const lines = [JSON.stringify({ type: "session", cwd, title: "Fix things", timestamp: replies[0][0] })];
	for (const [at, cost] of replies) {
		lines.push(JSON.stringify({
			type: "message", timestamp: at,
			message: { role: "assistant", model: "claude-test", usage: { totalTokens: 10, cacheRead: 8, cost: { total: cost } } },
		}));
	}
	mkdirSync(join(sessions, file, ".."), { recursive: true });
	writeFileSync(join(sessions, file), lines.join("\n") + "\n");
}

beforeAll(() => {
	base = realpathSync(mkdtempSync(join(tmpdir(), "overseer-usage-")));
	sessions = join(base, "sessions");
	repo = join(base, "app");
	mkdirSync(repo, { recursive: true });
	const git = (...args: string[]) => execFileSync("git", ["-C", repo, ...args], { stdio: "ignore" });
	git("init", "-q", "-b", "main");
	git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init");
	git("worktree", "add", "-q", "-b", "feature/odd", join(base, "elsewhere", "odd-name"));

	session("a/primary.jsonl", join(repo, "src"), [[day(0, 0, 30), 1], [day(-6, 0, 10), 2], [day(-7, 23, 50), 4]]);
	session("b/linked.jsonl", join(base, "elsewhere", "odd-name"), [[day(-1, 12), 8]]);
	session("c/removed.jsonl", join(base, "app.feature-gone"), [[day(-2, 12), 16]]);
	session("d/other.jsonl", join(base, "unrelated"), [[day(-3, 12), 32]]);
	session("a/primary/sub.jsonl", join(repo, "src"), [[day(0, 1), 64]]);
});

afterAll(() => rmSync(base, { recursive: true, force: true }));

const result = () => summarize([{ name: "app", path: repo, id: join(repo, ".git") }], sessions, now);

test("7 days is today and the six days before, whole days", () => {
	const { today, week, month } = result().ranges as Record<string, { cost: number; since: string; series: number[] }>;
	expect(today.cost).toBe(1 + 64);
	expect(week.cost).toBe(1 + 2 + 8 + 16 + 32 + 64);
	expect(month.cost).toBe(1 + 2 + 4 + 8 + 16 + 32 + 64);
	expect(week.series).toHaveLength(7);
	expect(week.series[0]).toBe(2);
	expect(week.series[6]).toBe(1 + 64);
	const start = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 6);
	expect(week.since).toStartWith("Since " + start.toLocaleDateString("en-US", { weekday: "long" }));
});

test("sessions group under Overseer's projects, the rest under Other", () => {
	const { week } = result().ranges as Record<string, { repos: { name: string; cost: number; worktrees: { name: string; cost: number }[] }[] }>;
	const app = week.repos.find(r => r.name === "app")!;
	const trees = Object.fromEntries(app.worktrees.map(tree => [tree.name, tree.cost]));
	expect(trees).toEqual({ "Primary checkout": 2 + 1 + 64, "odd-name": 8, "feature-gone": 16 });
	expect(week.repos.at(-1)!.name).toBe("Other");
	expect(week.repos.at(-1)!.cost).toBe(32);
});

test("subagents add to spend but not to sessions", () => {
	const { today } = result().ranges as Record<string, { sessions: number; subagents: number; top: { cost: number }[] }>;
	expect(today.subagents).toBe(64);
	expect(today.sessions).toBe(1);
	expect(today.top).toEqual([expect.objectContaining({ cost: 1 })]);
});
