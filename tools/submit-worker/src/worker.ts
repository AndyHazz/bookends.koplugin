// bookends-submit: accepts preset submissions from the plugin and opens
// pull requests on AndyHazz/bookends-presets. Zero-auth for submitters;
// a GitHub PAT stored as a Worker secret handles the PR side.

interface Env {
    GITHUB_TOKEN: string;       // fine-grained PAT with contents+PRs:write on AndyHazz/bookends-presets
    GITHUB_OWNER?: string;      // default "AndyHazz"
    GITHUB_REPO?: string;       // default "bookends-presets"
    MAX_OPEN_PRS?: string;      // default "20"
    IP_COOLDOWN_SECONDS?: string; // default "300"
}

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
    if (typeof body.slug !== "string" || !/^[a-z0-9-]+$/.test(body.slug) || body.slug.length > 64) {
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

export default {
    async fetch(request: Request, env: Env): Promise<Response> {
        const url = new URL(request.url);
        if (url.pathname === "/health") return json(200, { ok: true });
        if (url.pathname === "/submit") return handleSubmit(request, env);
        return json(404, { ok: false, error: "not found" });
    },
};
