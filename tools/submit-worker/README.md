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

Cloudflare Workers free plan: 100,000 requests/day. Realistic usage is single digits per day. Free tier has no credit-card requirement.

GitHub PAT rate limit: 5,000 API calls/hour. Each submission burns ~6 calls (ref, contents, branch, 2x file commits, PR). Headroom for ~800 submissions/hour before hitting GitHub's limit.

## Monitoring

```bash
npx wrangler tail
```

Streams live request logs. Useful for debugging.

## Files

- `src/worker.ts` — the Worker code
- `wrangler.toml` — Cloudflare config
- `package.json` — Node dependencies
- `tsconfig.json` — TypeScript config
