// bookends-submit: accepts preset submissions from the plugin and opens
// pull requests on AndyHazz/bookends-presets. Zero-auth for submitters;
// a GitHub PAT stored as a Worker secret handles the PR side.

interface Env {
    GITHUB_TOKEN: string;       // fine-grained PAT with contents+PRs:write on AndyHazz/bookends-presets
    GITHUB_OWNER?: string;      // default "AndyHazz"
    GITHUB_REPO?: string;       // default "bookends-presets"
    MAX_OPEN_PRS?: string;      // default "20"
    IP_COOLDOWN_SECONDS?: string; // default "300"
    INSTALL_DEDUPE_TTL_SECONDS?: string; // default "86400" (24h)
    COUNTS_CACHE_SECONDS?: string;       // default "60"
    INSTALL_COUNTS: KVNamespace;         // created out-of-band; see wrangler.toml
}

const SLUG_RE = /^[a-z0-9-]+$/;

interface SubmitBody {
    slug?: string;
    name?: string;
    author?: string;
    description?: string;
    preset_lua?: string;
}

// Per-instance IP cooldown. Workers free tier runs multiple isolates so
// this isn't perfectly durable, but it stops naive floods; the open-PR cap
// is the real backstop.
const recentSubmissions = new Map<string, number>();

function json(status: number, body: Record<string, unknown>): Response {
    return new Response(JSON.stringify(body), {
        status,
        headers: {
            "content-type": "application/json",
            "access-control-allow-origin": "*",
            "access-control-allow-methods": "POST, OPTIONS",
            "access-control-allow-headers": "content-type",
        },
    });
}

function validate(body: SubmitBody): string | null {
    if (!body || typeof body !== "object") return "body must be a JSON object";
    if (typeof body.slug !== "string" || !SLUG_RE.test(body.slug) || body.slug.length > 64) {
        return "slug must match [a-z0-9-]+ and be ≤64 chars";
    }
    if (typeof body.name !== "string" || !body.name.trim() || body.name.length > 120) {
        return "name is required, ≤120 chars";
    }
    if (typeof body.author !== "string" || !body.author.trim() || body.author.length > 120) {
        return "author is required, ≤120 chars";
    }
    if (typeof body.description !== "string" || !body.description.trim() || body.description.length > 120) {
        return "description is required, ≤120 chars";
    }
    if (typeof body.preset_lua !== "string" || body.preset_lua.length > 32 * 1024) {
        return "preset_lua is required and ≤32 KB";
    }
    if (!body.preset_lua.startsWith("-- Bookends preset:")) {
        return "preset_lua must start with '-- Bookends preset:'";
    }
    return null;
}

async function gh<T>(env: Env, path: string, init?: RequestInit): Promise<T> {
    const resp = await fetch(`https://api.github.com${path}`, {
        ...init,
        headers: {
            "authorization": `Bearer ${env.GITHUB_TOKEN}`,
            "accept": "application/vnd.github+json",
            "user-agent": "bookends-submit-worker",
            ...(init?.headers || {}),
        },
    });
    if (!resp.ok) {
        const text = await resp.text();
        throw new Error(`GitHub ${resp.status}: ${text.slice(0, 400)}`);
    }
    return resp.json() as Promise<T>;
}

function b64(s: string): string {
    // Worker runtime has btoa but only for Latin-1; use Buffer-like approach via encoded bytes.
    const bytes = new TextEncoder().encode(s);
    let bin = "";
    for (const b of bytes) bin += String.fromCharCode(b);
    return btoa(bin);
}


async function handleSubmit(request: Request, env: Env): Promise<Response> {
    if (request.method === "OPTIONS") return json(204, {});
    if (request.method !== "POST") return json(405, { ok: false, error: "use POST" });

    const owner = env.GITHUB_OWNER ?? "AndyHazz";
    const repo = env.GITHUB_REPO ?? "bookends-presets";
    const maxOpenPrs = parseInt(env.MAX_OPEN_PRS ?? "20", 10);
    const cooldown = parseInt(env.IP_COOLDOWN_SECONDS ?? "300", 10);

    // IP cooldown
    const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
    const now = Date.now();
    // Clean expired entries opportunistically
    for (const [k, t] of recentSubmissions) {
        if (now - t > cooldown * 1000) recentSubmissions.delete(k);
    }
    const last = recentSubmissions.get(ip);
    if (last && now - last < cooldown * 1000) {
        const wait = Math.ceil((cooldown * 1000 - (now - last)) / 1000);
        return json(429, { ok: false, error: `slow down — try again in ${wait}s` });
    }

    // Parse + validate
    let body: SubmitBody;
    try {
        body = await request.json();
    } catch {
        return json(400, { ok: false, error: "invalid JSON" });
    }
    const err = validate(body);
    if (err) return json(400, { ok: false, error: err });

    // Global open-PR cap
    try {
        const openPrs = await gh<Array<unknown>>(env, `/repos/${owner}/${repo}/pulls?state=open&per_page=${maxOpenPrs + 1}`);
        if (openPrs.length >= maxOpenPrs) {
            return json(503, { ok: false, error: "gallery backlog is full, try again later" });
        }
    } catch (e) {
        return json(502, { ok: false, error: `github check failed: ${(e as Error).message}` });
    }

    // Fetch main's SHA
    let mainSha: string;
    try {
        const ref = await gh<{ object: { sha: string } }>(env, `/repos/${owner}/${repo}/git/refs/heads/main`);
        mainSha = ref.object.sha;
    } catch (e) {
        return json(502, { ok: false, error: `github fetch failed: ${(e as Error).message}` });
    }

    const presetPath = `presets/${body.slug}.lua`;

    // Duplicate-slug check: does the preset file already exist on main?
    try {
        await gh(env, `/repos/${owner}/${repo}/contents/${presetPath}?ref=main`);
        // If the GET succeeds (200), the file exists.
        return json(409, { ok: false, error: "slug already exists in the gallery" });
    } catch (e) {
        // 404 is expected (file doesn't exist yet); other errors bubble up.
        if (!/ 404: /.test((e as Error).message)) {
            return json(502, { ok: false, error: `github check failed: ${(e as Error).message}` });
        }
    }

    // Already-open-submission check: if a submit/<slug>-* branch exists, reject
    try {
        const branches = await gh<Array<{ name: string }>>(
            env, `/repos/${owner}/${repo}/branches?per_page=100`);
        for (const b of branches) {
            if (b.name.startsWith(`submit/${body.slug}-`)) {
                return json(409, { ok: false, error: "a submission for this slug is already open" });
            }
        }
    } catch (e) {
        return json(502, { ok: false, error: `github branches failed: ${(e as Error).message}` });
    }

    const shortTs = Math.floor(Date.now() / 1000).toString(36);
    const branchName = `submit/${body.slug}-${shortTs}`;

    // Create the branch at main's SHA, then commit the preset file, then open PR.
    // index.json is NOT touched — a GitHub Action on the presets repo regenerates
    // it from presets/*.lua on every push to main, so submissions can't conflict.
    try {
        await gh(env, `/repos/${owner}/${repo}/git/refs`, {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ ref: `refs/heads/${branchName}`, sha: mainSha }),
        });

        await gh(env, `/repos/${owner}/${repo}/contents/${presetPath}`, {
            method: "PUT",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({
                message: `Add preset: ${body.name}`,
                content: b64(body.preset_lua!),
                branch: branchName,
            }),
        });

        const pr = await gh<{ html_url: string; number: number }>(
            env, `/repos/${owner}/${repo}/pulls`, {
                method: "POST",
                headers: { "content-type": "application/json" },
                body: JSON.stringify({
                    title: `Submission: ${body.name} by ${body.author}`,
                    head: branchName,
                    base: "main",
                    body: [
                        `**${body.name}** — ${body.description}`,
                        ``,
                        `Submitted by **${body.author}** via the bookends preset manager.`,
                        ``,
                        `- Slug: \`${body.slug}\``,
                        `- File: [\`${presetPath}\`](../blob/${branchName}/${presetPath})`,
                    ].join("\n"),
                }),
            });

        recentSubmissions.set(ip, now);
        return json(200, { ok: true, pr_url: pr.html_url, pr_number: pr.number });
    } catch (e) {
        return json(502, { ok: false, error: `github write failed: ${(e as Error).message}` });
    }
}

// Hash ip+slug into a short opaque dedupe key — we don't want to store raw IPs
// in KV even ephemerally. SHA-256 truncated to 16 hex chars is plenty to keep
// the keyspace collision-free across realistic install volumes.
async function ipSlugKey(ip: string, slug: string): Promise<string> {
    const data = new TextEncoder().encode(`${ip}:${slug}`);
    const digest = await crypto.subtle.digest("SHA-256", data);
    const bytes = new Uint8Array(digest).slice(0, 8);
    let hex = "";
    for (const b of bytes) hex += b.toString(16).padStart(2, "0");
    return hex;
}

const COUNTS_CACHE_KEY = "https://bookends-submit.internal/counts";

// Every install counter lives in ONE key as a { slug: n } blob, rather than a
// key per preset.
//
// The per-preset layout made /counts cost one list plus one get per preset,
// serialised. At 170 presets that measured 5.0 s cold and 171 KV reads a call --
// which both froze the gallery (the plugin's fetch is synchronous on the UI
// thread) and burned the 100k/day free-tier read allowance in a few hundred
// refreshes. The edge cache in front of it barely helped, because handleInstall
// invalidates it on every genuine install. Reading one key instead makes /counts
// a single read whatever the gallery grows to.
//
// The install path costs exactly what it did before -- it was
// get(count:slug) + put(count:slug) + put(lock), now it's
// get(counts:all) + put(counts:all) + put(lock) -- so this spends nothing extra
// from the much tighter 1k/day write allowance.
//
// Tradeoff: all bumps now read-modify-write the same key, so two installs of
// *different* presets landing together can lose one, where separate keys would
// have kept both. Same-slug contention could already lose bumps, and this is a
// popularity signal rather than an accounting record, so the wider window is
// acceptable. If it ever stops being acceptable the answer is D1, not more keys.
const COUNTS_KEY = "counts:all";

// The pre-blob layout. Read once to seed COUNTS_KEY, then never again -- the
// existence of COUNTS_KEY is itself the "already migrated" marker, so there's no
// separate flag to keep in sync. These keys are deliberately left in place
// rather than deleted (deletes have their own daily allowance and stale keys
// cost nothing), but they stop being updated the moment the blob exists, so
// treat them as historical and never as a source of truth.
const LEGACY_COUNT_PREFIX = "count:";

/** Seed the aggregate blob from the legacy per-preset keys. Runs at most once. */
async function migrateLegacyCounts(env: Env): Promise<Record<string, number>> {
    const counts: Record<string, number> = {};
    let cursor: string | undefined;
    do {
        const page = await env.INSTALL_COUNTS.list({ prefix: LEGACY_COUNT_PREFIX, cursor });
        // Parallel, unlike the loop this replaces: it only runs once, but once
        // was still 5 s of sequential round trips.
        const values = await Promise.all(page.keys.map((k) => env.INSTALL_COUNTS.get(k.name)));
        page.keys.forEach((k, i) => {
            const n = parseInt(values[i] ?? "0", 10);
            if (!Number.isNaN(n)) counts[k.name.slice(LEGACY_COUNT_PREFIX.length)] = n;
        });
        cursor = page.list_complete ? undefined : page.cursor;
    } while (cursor);
    // Written even when empty, so "absent" unambiguously means "never migrated"
    // and a fresh namespace doesn't re-scan on every request. Persisted in the
    // current { totals, days } shape rather than the flat one it replaced, so
    // the stored document is canonical straight away -- loadCountsDoc would
    // cope either way, but leaving a superseded shape on disk invites someone
    // later to read it directly and get it wrong. No day buckets: the legacy
    // counters are totals with no dates to attribute them to.
    await env.INSTALL_COUNTS.put(COUNTS_KEY, JSON.stringify({ totals: counts, days: {} }));
    return counts;
}

// Per-day install buckets, so "popular this week/month" is answerable later.
//
// Deliberately folded into the SAME key as the totals rather than living in a
// `counts:<date>` key of its own. A separate key would cost a second write per
// install, taking the per-install cost back to the 2 writes we just halved --
// and writes are the tightest free-tier limit (1k/day) by two orders of
// magnitude. Sharing the key keeps install at exactly one read and one write
// however many windows we later want to report.
//
// Buckets are sparse: a day only lists slugs actually installed that day, so at
// ~350 installs/day over ~100 distinct slugs this is a few KB per day against a
// 25 MB value ceiling. RETENTION_DAYS is pruned on write so it can't creep.
//
// No historical backfill is possible -- the pre-existing counters were totals
// with no dates attached. The legacy `count:<slug>` keys are a frozen snapshot
// from the 2026-08-23 migration, which is the one historical datapoint that
// exists; diffing them against totals gives installs-since-then. DON'T DELETE
// THEM, they can't be regenerated.
const RETENTION_DAYS = 35;

interface CountsDoc {
    totals: Record<string, number>;
    days: Record<string, Record<string, number>>;   // "YYYY-MM-DD" -> slug -> n
}

/** UTC day key. UTC not local, so buckets line up with the KV quota window. */
function dayKey(now: Date): string {
    return now.toISOString().slice(0, 10);
}

/** Drop buckets older than RETENTION_DAYS. In-memory; caller persists. */
function pruneDays(doc: CountsDoc, now: Date): void {
    const cutoff = new Date(now.getTime() - RETENTION_DAYS * 86400_000);
    const oldest = dayKey(cutoff);
    for (const day of Object.keys(doc.days)) {
        if (day < oldest) delete doc.days[day];   // ISO dates sort lexically
    }
}

/**
 * The counts document, upgrading older shapes on read.
 *
 * Three shapes exist in the wild and all must load:
 *   { totals, days }            current
 *   { slug: n }                 the flat blob shipped 2026-08-23
 *   absent                      pre-blob; seed from the legacy count: keys
 *
 * The flat shape is detected by the absence of a `totals` object. Upgrading is
 * in-memory only; it persists on the next install, so a read-only day costs no
 * write.
 */
async function loadCountsDoc(env: Env): Promise<CountsDoc> {
    const blob = await env.INSTALL_COUNTS.get<Record<string, unknown>>(COUNTS_KEY, "json");
    if (blob && typeof blob === "object") {
        if (blob.totals && typeof blob.totals === "object") {
            return {
                totals: blob.totals as Record<string, number>,
                days: (blob.days && typeof blob.days === "object"
                    ? blob.days : {}) as Record<string, Record<string, number>>,
            };
        }
        return { totals: blob as Record<string, number>, days: {} };
    }
    return { totals: await migrateLegacyCounts(env), days: {} };
}

/** Sum the per-day buckets over the last `windowDays` days, inclusive of today. */
function rollup(doc: CountsDoc, windowDays: number, now: Date): Record<string, number> {
    const from = dayKey(new Date(now.getTime() - (windowDays - 1) * 86400_000));
    const out: Record<string, number> = {};
    for (const [day, slugs] of Object.entries(doc.days)) {
        if (day < from) continue;
        for (const [slug, n] of Object.entries(slugs)) out[slug] = (out[slug] ?? 0) + n;
    }
    return out;
}

async function handleInstall(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    if (request.method === "OPTIONS") return json(204, {});
    if (request.method !== "POST") return json(405, { ok: false, error: "use POST" });

    let body: { slug?: string };
    try {
        body = await request.json();
    } catch {
        return json(400, { ok: false, error: "invalid JSON" });
    }
    const slug = body?.slug;
    if (typeof slug !== "string" || !SLUG_RE.test(slug) || slug.length > 64) {
        return json(400, { ok: false, error: "slug must match [a-z0-9-]+ and be ≤64 chars" });
    }

    const ttl = parseInt(env.INSTALL_DEDUPE_TTL_SECONDS ?? "86400", 10);
    const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
    // Dedupe lock lives in the edge cache, not KV.
    //
    // A fresh install used to cost two KV writes: the counter, and an
    // `iplock:` key purely to remember "this IP already counted this slug".
    // Writes are the tightest thing in the free tier by a distance — 1k/day
    // against 100k reads — and measured 720/day, i.e. 72% of the cap for
    // roughly 360 installs. Halving the per-install write cost halves that.
    //
    // The tradeoff is that the Cache API is per-colo rather than global, so
    // the lock only holds at the edge location that served the install. A
    // reader whose requests move between colos (mobile handover, VPN) could
    // be counted twice, and cache eviction under pressure can drop a lock
    // early. Both are acceptable for a popularity signal, and neither can
    // inflate a count by more than a handful.
    const lockKey = new Request(
        `https://bookends-submit.internal/iplock/${slug}/${await ipSlugKey(ip, slug)}`,
    );

    // If the same IP already pinged this slug within TTL, silently succeed
    // without bumping the counter. The client treats 200 as success either way.
    const cache = (caches as unknown as { default: Cache }).default;
    if (await cache.match(lockKey)) {
        return json(200, { ok: true, deduped: true });
    }

    // Read-modify-write: KV has no atomic increments. Under contention we may
    // lose the occasional bump, which is fine for a popularity signal. See the
    // COUNTS_KEY note on why that window is wider than it used to be.
    const doc = await loadCountsDoc(env);
    const next = (doc.totals[slug] ?? 0) + 1;
    doc.totals[slug] = next;

    // Same bump recorded against today's bucket, so windowed "popular this
    // week/month" is answerable later. Costs no extra KV operation: it rides
    // along in the write the totals were doing anyway.
    const now = new Date();
    const today = dayKey(now);
    const bucket = doc.days[today] ?? (doc.days[today] = {});
    bucket[slug] = (bucket[slug] ?? 0) + 1;
    pruneDays(doc, now);

    // Still one KV write per install.
    await env.INSTALL_COUNTS.put(COUNTS_KEY, JSON.stringify(doc));

    // Take the dedupe lock. Cache-Control is what gives it its lifetime, so the
    // TTL setting still applies; it just expires at the edge instead of in KV.
    ctx.waitUntil(cache.put(lockKey, new Response("1", {
        headers: { "cache-control": `public, max-age=${ttl}` },
    })));

    // Invalidate the edge-cached /counts so a user who just installed a preset
    // and hits Refresh sees their bump reflected. Dedupe hits above (which
    // don't bump) skip this — the cache stays warm for the common path.
    ctx.waitUntil(cache.delete(new Request(COUNTS_CACHE_KEY)));

    return json(200, { ok: true, count: next });
}

async function handleCounts(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    if (request.method !== "GET") return json(405, { ok: false, error: "use GET" });

    // Edge-cache the response so bursts of gallery refreshes collapse to one KV
    // read. The cache key is the canonical URL without query string so clients
    // can't DoS the cache with ever-changing ?ts= values; staleness is bounded
    // by COUNTS_CACHE_SECONDS and the /install handler explicitly invalidates
    // this entry whenever it actually bumps a counter. That invalidation used to
    // be expensive to recover from (a full 171-read rescan); with COUNTS_KEY the
    // miss path is a single read, so a cold cache is no longer a cliff.
    const cacheKey = new Request(COUNTS_CACHE_KEY);
    const cache = (caches as unknown as { default: Cache }).default;
    const cached = await cache.match(cacheKey);
    if (cached) return cached;

    // Response shape is frozen: { ok, counts }. Released plugin versions parse
    // exactly this, and the per-day data is deliberately NOT added here -- it
    // would inflate a payload every gallery refresh downloads, for data no
    // shipped client reads yet. It lives on /trending instead.
    const counts = (await loadCountsDoc(env)).totals;

    const maxAge = parseInt(env.COUNTS_CACHE_SECONDS ?? "60", 10);
    const resp = new Response(JSON.stringify({ ok: true, counts }), {
        status: 200,
        headers: {
            "content-type": "application/json",
            "access-control-allow-origin": "*",
            "cache-control": `public, max-age=${maxAge}, s-maxage=${maxAge}`,
        },
    });
    ctx.waitUntil(cache.put(cacheKey, resp.clone()));
    return resp;
}

const TRENDING_CACHE_KEY = "https://bookends-submit.internal/trending";

/**
 * GET /trending -> { ok, generated, windows: { "7": {slug:n}, "30": {slug:n} },
 *                    days_retained, days_recorded }
 *
 * Windowed install counts from the per-day buckets. Separate from /counts so
 * that endpoint's payload and response shape stay untouched for released
 * clients; this one costs the same single KV read.
 *
 * Expect thin numbers until the buckets fill: recording started 2026-08-27, and
 * nothing before that has dates. days_recorded tells a caller how much history
 * actually backs the answer, so a client can hide a "this month" sort until
 * there is a month of it rather than showing a confidently wrong ranking.
 */
async function handleTrending(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    if (request.method !== "GET") return json(405, { ok: false, error: "use GET" });

    const cacheKey = new Request(TRENDING_CACHE_KEY);
    const cache = (caches as unknown as { default: Cache }).default;
    const cached = await cache.match(cacheKey);
    if (cached) return cached;

    const doc = await loadCountsDoc(env);
    const now = new Date();
    const body = {
        ok: true,
        generated: now.toISOString(),
        days_retained: RETENTION_DAYS,
        days_recorded: Object.keys(doc.days).length,
        windows: { "7": rollup(doc, 7, now), "30": rollup(doc, 30, now) },
    };

    const maxAge = parseInt(env.COUNTS_CACHE_SECONDS ?? "60", 10);
    const resp = new Response(JSON.stringify(body), {
        status: 200,
        headers: {
            "content-type": "application/json",
            "access-control-allow-origin": "*",
            "cache-control": `public, max-age=${maxAge}, s-maxage=${maxAge}`,
        },
    });
    ctx.waitUntil(cache.put(cacheKey, resp.clone()));
    return resp;
}

export default {
    async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
        const url = new URL(request.url);
        if (url.pathname === "/health") return json(200, { ok: true });
        if (url.pathname === "/submit") return handleSubmit(request, env);
        if (url.pathname === "/install") return handleInstall(request, env, ctx);
        if (url.pathname === "/counts") return handleCounts(request, env, ctx);
        if (url.pathname === "/trending") return handleTrending(request, env, ctx);
        return json(404, { ok: false, error: "not found" });
    },
};
