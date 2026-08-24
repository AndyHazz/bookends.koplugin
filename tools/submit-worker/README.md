# bookends-submit Worker

Cloudflare Worker that receives preset submissions from the bookends plugin and opens pull requests on [`AndyHazz/bookends-presets`](https://github.com/AndyHazz/bookends-presets).

Sits between the plugin and GitHub. Plugin users get one-tap in-app submission; the maintainer reviews each as a normal PR.

## First-time deploy

Prerequisites: Node.js (any LTS), a personal Cloudflare account (free plan is fine), a GitHub account with push access to `bookends-presets`.

```bash
cd tools/submit-worker
npm install
```

### 1. Log wrangler into your Cloudflare account

```bash
npx wrangler login
```

Opens a browser, sign in to your **personal** account, approve. One-time.

### 2. Create a GitHub fine-grained PAT

Go to https://github.com/settings/personal-access-tokens/new — create a **fine-grained token** restricted to *only* the `bookends-presets` repo with these permissions:

- **Contents** — Read and write
- **Pull requests** — Read and write
- **Metadata** — Read (required automatically)

Give it a 1-year expiry (or a custom "never" if your org permits). Copy the token (starts with `github_pat_...`).

### 3. Give the Worker the token

```bash
npx wrangler secret put GITHUB_TOKEN
# paste the token when prompted
```

### 4. Deploy

```bash
npx wrangler deploy
```

Output includes the live URL, something like:

```
https://bookends-submit.<your-handle>.workers.dev
```

### 5. Smoke-test

```bash
curl -s https://bookends-submit.<your-handle>.workers.dev/health
# → {"ok":true}
```

### 6. Wire the plugin to this URL

Edit `preset_gallery.lua` in the plugin repo — set `SUBMIT_URL` to your deployed URL. Commit + release.

## Redeploying after code changes

```bash
cd tools/submit-worker
npx wrangler deploy
```

## Tuning

Non-secret settings live in `wrangler.toml` under `[vars]`:

| Var | Default | Effect |
|---|---|---|
| `GITHUB_OWNER` | `AndyHazz` | Target repo owner |
| `GITHUB_REPO` | `bookends-presets` | Target repo name |
| `MAX_OPEN_PRS` | `20` | Reject new submissions when more than this many submission PRs are already open |
| `IP_COOLDOWN_SECONDS` | `300` | Per-IP cooldown between submissions |

Change these in the dashboard (Workers → bookends-submit → Settings → Variables) or edit `wrangler.toml` and redeploy.

## How index.json stays up to date

The Worker **does not touch `index.json`**. Submissions only commit the preset file (`presets/<slug>.lua`) and open a PR.

`bookends-presets` has a GitHub Action (`.github/workflows/regenerate-index.yml`) that watches `presets/*.lua` on `main` and regenerates `index.json` automatically on every push. This means submission PRs never conflict on `index.json` — they only add disjoint preset files.

## Abuse controls

Two layers:

1. **Per-IP cooldown** — 5 min default. In-memory across a single Worker isolate, so not perfectly durable; stops naive flooders.
2. **Global open-PR cap** — if more than `MAX_OPEN_PRS` submission PRs are open, new submissions are rejected with a "backlog full" error. Real backstop against slow persistent abuse.

If you see the queue getting flooded:

- Mass-close submission PRs: `gh pr list --repo AndyHazz/bookends-presets --label submission --limit 100 --json number -q '.[].number' | xargs -I{} gh pr close --repo AndyHazz/bookends-presets --delete-branch {}`
- Temporarily disable the Worker via the Cloudflare dashboard (disables inbound requests without breaking anything)

## Free tier headroom

Two separate sets of limits. The Worker request limit has never been close; the **KV operation limits** are the ones that bite, and they bit hard in August 2026.

| Limit | Free tier (per UTC day) | What consumes it |
|---|---|---|
| Worker requests | 100,000 | every `/counts`, `/install`, `/submit` |
| **KV reads** | **100,000** | one per `/counts` cache miss |
| **KV writes** | **1,000** | one per counted install |
| KV lists | 1,000 | none any more |
| KV deletes | 1,000 | none |

Exceeding a KV cap is not throttling: the API returns 429 and operations inside the Worker fail. `Gallery.fetchCounts` treats failure as non-fatal and just hides the Popular sort, so it presents as "install counts sometimes don't show" rather than an error.

**What went wrong.** `/counts` used to do a `list` plus one `get` per preset. At 170 presets that was 171 reads a call, and because `/install` invalidates the edge cache on every install, callers kept landing on the cold path. Reads climbed with the gallery and went over the cap on three days:

```
2026-08-17    50150  50%
2026-08-19   102880 103%   <- over cap, gallery counts failing
2026-08-21   108230 108%   <- over cap
2026-08-22   116100 116%   <- over cap
2026-08-23    86490  86%   <- aggregate-key fix deployed 18:xx UTC
2026-08-24      220   0%
```

Two changes fixed it, both in `worker.ts`:

- **All counters in one `counts:all` blob.** `/counts` is a single read regardless of gallery size, instead of `1 + N`. Reads dropped ~100x and no longer scale with the number of presets.
- **Dedupe lock in the edge cache, not KV.** A counted install was two writes (counter + `iplock:` key); the lock doesn't need KV's durability or global consistency, so it moved to the Cache API. One write per install, and a deduped install costs zero KV operations.

Writes now sit around a third of the cap at ~350 installs/day. That is headroom, not immunity — it scales linearly with popularity, so roughly 1,000 counted installs a day would reach the cap again. **At that point the answer is D1** (100,000 writes/day, and real atomic increments, which would also retire the lost-bump race the single blob introduced). Deliberately not done yet: it's a migration, and there's no point paying for it while a third of one limit is the worst number on the board.

GitHub PAT rate limit: 5,000 API calls/hour. Each submission burns ~6 calls (ref, contents, branch, 2x file commits, PR), so ~800 submissions/hour before GitHub's limit matters.

## Monitoring

Daily KV operations against each cap:

```bash
./scripts/kv-usage.sh          # last 7 days
./scripts/kv-usage.sh 1 hourly # today, accumulating toward the daily caps
```

Worth running when a Cloudflare limit email arrives, because those emails are **batched rather than sent on the crossing** and don't say which limit. One threshold crossed at 12:00 UTC arrived at 2am the following morning, by which point it was describing a window that had already closed — and a warning about the previous day's reads is easy to mistake for a new problem with writes.

Live request logs, for debugging:

```bash
npx wrangler tail
```

## Files

- `src/worker.ts` — the Worker code
- `test/counts.test.mjs` — `npm test`; drives the compiled Worker against a mock KV that tallies every get/put/list, so the operation counts above are asserted rather than assumed
- `scripts/kv-usage.sh` — daily KV operations vs the free-tier caps
- `wrangler.toml` — Cloudflare config
- `package.json` — Node dependencies (`npm test`, `npm run typecheck`, `npm run deploy`)
- `tsconfig.json` — TypeScript config

Note: `wrangler dev` needs to bind `[::1]`, so it will not start on a host with IPv6 disabled. `npm test` covers the KV logic without it.
