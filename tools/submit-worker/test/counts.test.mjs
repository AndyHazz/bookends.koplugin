// Exercises the COUNTS_KEY aggregate-blob change against a mock KV namespace.
// The point of the change is the operation COUNT, not just the values, so the
// mock tallies every get/put/list and the assertions check those tallies.

import worker from "../dist/worker.mjs";

let ops;
function resetOps() { ops = { get: 0, put: 0, list: 0 }; }
resetOps();

function makeKV(seed = {}) {
    const store = new Map(Object.entries(seed));
    return {
        _store: store,
        async get(key, type) {
            ops.get++;
            const v = store.has(key) ? store.get(key) : null;
            if (type === "json") return v === null ? null : JSON.parse(v);
            return v;
        },
        async put(key, value) { ops.put++; store.set(key, value); },
        async list({ prefix }) {
            ops.list++;
            const keys = [...store.keys()].filter((k) => k.startsWith(prefix)).map((name) => ({ name }));
            return { keys, list_complete: true, cursor: undefined };
        },
    };
}

// Minimal Cache API stand-in. Deliberately not counted in ops -- the Cache API
// is separate from the KV allowance, which is the whole reason caching alone
// couldn't fix the quota problem.
function installCacheMock() {
    const entries = new Map();
    globalThis.caches = {
        default: {
            async match(req) {
                const hit = entries.get(req.url);
                return hit ? hit.clone() : undefined;
            },
            async put(req, resp) { entries.set(req.url, resp.clone()); },
            async delete(req) { return entries.delete(req.url); },
        },
    };
    return entries;
}

const ctx = { waitUntil: (p) => { if (p && typeof p.then === "function") p.catch(() => {}); } };
const env = () => ({ INSTALL_DEDUPE_TTL_SECONDS: "86400", COUNTS_CACHE_SECONDS: "60" });

let pass = 0, fail = 0;
async function test(name, fn) {
    try { await fn(); pass++; }
    catch (e) { fail++; console.error(`FAIL  ${name}\n  ${e.message}`); }
}
function eq(actual, expected, msg) {
    const a = JSON.stringify(actual), b = JSON.stringify(expected);
    if (a !== b) throw new Error(`${msg ?? ""} expected=${b} got=${a}`);
}

const countsReq = () => new Request("https://w.dev/counts");
const installReq = (slug, ip) => new Request("https://w.dev/install", {
    method: "POST",
    headers: { "content-type": "application/json", "cf-connecting-ip": ip },
    body: JSON.stringify({ slug }),
});

// ---------------------------------------------------------------------------

await test("migrates legacy per-preset keys into the blob on first /counts", async () => {
    installCacheMock(); resetOps();
    const e = { ...env(), INSTALL_COUNTS: makeKV({ "count:alpha": "5", "count:beta": "3" }) };
    const r = await worker.fetch(countsReq(), e, ctx);
    const body = await r.json();
    eq(body.ok, true, "ok");
    eq(body.counts, { alpha: 5, beta: 3 }, "counts");
    eq(JSON.parse(e.INSTALL_COUNTS._store.get("counts:all")).totals, { alpha: 5, beta: 3 }, "blob written");
});

await test("post-migration /counts costs exactly ONE kv read, no list", async () => {
    installCacheMock();
    const e = { ...env(), INSTALL_COUNTS: makeKV({ "counts:all": JSON.stringify({ alpha: 5, beta: 3 }) }) };
    resetOps();
    const r = await worker.fetch(countsReq(), e, ctx);
    eq((await r.json()).counts, { alpha: 5, beta: 3 }, "counts");
    eq(ops.get, 1, "kv gets");
    eq(ops.list, 0, "kv lists");
    eq(ops.put, 0, "kv puts");
});

await test("the legacy scan runs once at 170 presets, then never again", async () => {
    // Guards the regression this change exists to prevent: if the per-key scan
    // is ever reintroduced on the read path, the second-call count stops being 1.
    installCacheMock(); resetOps();
    const seed = {};
    for (let i = 0; i < 170; i++) seed[`count:p${i}`] = String(i);
    const e = { ...env(), INSTALL_COUNTS: makeKV(seed) };
    await worker.fetch(countsReq(), e, ctx);
    eq(ops.list, 1, "one list during migration");
    eq(ops.get, 171, "blob probe + 170 legacy gets, once ever");
    resetOps(); installCacheMock();
    await worker.fetch(countsReq(), e, ctx);
    eq(ops.get, 1, "second call is a single read");
    eq(ops.list, 0, "no further lists");
});

await test("empty namespace writes an empty blob so it never rescans", async () => {
    installCacheMock(); resetOps();
    const e = { ...env(), INSTALL_COUNTS: makeKV() };
    const r = await worker.fetch(countsReq(), e, ctx);
    eq((await r.json()).counts, {}, "counts");
    eq(e.INSTALL_COUNTS._store.get("counts:all"), '{"totals":{},"days":{}}', "empty blob persisted");
    resetOps(); installCacheMock();
    await worker.fetch(countsReq(), e, ctx);
    eq(ops.list, 0, "no rescan on the next call");
});

await test("/install bumps the blob with a single KV write", async () => {
    installCacheMock();
    const e = { ...env(), INSTALL_COUNTS: makeKV({ "counts:all": JSON.stringify({ alpha: 5 }) }) };
    resetOps();
    const r = await worker.fetch(installReq("alpha", "1.2.3.4"), e, ctx);
    const body = await r.json();
    eq(body.ok, true, "ok");
    eq(body.count, 6, "returned count");
    eq(JSON.parse(e.INSTALL_COUNTS._store.get("counts:all")).totals, { alpha: 6 }, "blob bumped");
    // Was 2 (counter blob + iplock). The dedupe lock now lives in the edge
    // cache, which doesn't touch the KV allowance -- writes are the tightest
    // free-tier limit at 1k/day and this halves the per-install cost.
    eq(ops.put, 1, "kv puts (counter blob only)");
});

await test("/install on an unseen slug starts it at 1", async () => {
    installCacheMock();
    const e = { ...env(), INSTALL_COUNTS: makeKV({ "counts:all": JSON.stringify({ alpha: 5 }) }) };
    const r = await worker.fetch(installReq("brand-new", "1.2.3.4"), e, ctx);
    eq((await r.json()).count, 1, "count");
    eq(JSON.parse(e.INSTALL_COUNTS._store.get("counts:all")).totals, { alpha: 5, "brand-new": 1 }, "blob");
});

await test("/install dedupes a repeat from the same IP without bumping or writing", async () => {
    installCacheMock();
    const e = { ...env(), INSTALL_COUNTS: makeKV({ "counts:all": JSON.stringify({ alpha: 5 }) }) };
    await worker.fetch(installReq("alpha", "9.9.9.9"), e, ctx);
    const r2 = await worker.fetch(installReq("alpha", "9.9.9.9"), e, ctx);
    eq((await r2.json()).deduped, true, "deduped");
    eq(JSON.parse(e.INSTALL_COUNTS._store.get("counts:all")).totals, { alpha: 6 }, "only one bump");
    // A deduped install must cost nothing at all in KV: the lock check is a
    // cache lookup, so there's no longer even a read.
    resetOps();
    await worker.fetch(installReq("alpha", "9.9.9.9"), e, ctx);
    eq(ops.get, 0, "kv gets on a deduped install");
    eq(ops.put, 0, "kv puts on a deduped install");
});

await test("a different IP does bump the same slug", async () => {
    installCacheMock();
    const e = { ...env(), INSTALL_COUNTS: makeKV({ "counts:all": JSON.stringify({ alpha: 5 }) }) };
    await worker.fetch(installReq("alpha", "1.1.1.1"), e, ctx);
    await worker.fetch(installReq("alpha", "2.2.2.2"), e, ctx);
    eq(JSON.parse(e.INSTALL_COUNTS._store.get("counts:all")).totals, { alpha: 7 }, "two bumps");
});

await test("/install migrates from legacy keys if the blob isn't there yet", async () => {
    installCacheMock();
    const e = { ...env(), INSTALL_COUNTS: makeKV({ "count:alpha": "4" }) };
    const r = await worker.fetch(installReq("alpha", "5.5.5.5"), e, ctx);
    eq((await r.json()).count, 5, "legacy value carried into the bump");
    eq(JSON.parse(e.INSTALL_COUNTS._store.get("counts:all")).totals, { alpha: 5 }, "blob");
});

await test("/counts serves the edge cache without touching KV at all", async () => {
    installCacheMock();
    const e = { ...env(), INSTALL_COUNTS: makeKV({ "counts:all": JSON.stringify({ alpha: 1 }) }) };
    await worker.fetch(countsReq(), e, ctx);   // warms the cache
    resetOps();
    const r = await worker.fetch(countsReq(), e, ctx);
    eq((await r.json()).counts, { alpha: 1 }, "counts");
    eq(ops.get, 0, "kv gets on a cache hit");
});

await test("rejects a bad slug and a non-GET /counts", async () => {
    installCacheMock();
    const e = { ...env(), INSTALL_COUNTS: makeKV() };
    eq((await worker.fetch(installReq("Bad Slug!", "1.2.3.4"), e, ctx)).status, 400, "bad slug");
    eq((await worker.fetch(new Request("https://w.dev/counts", { method: "POST" }), e, ctx)).status, 405, "counts POST");
});


// --- per-day buckets (windowed "popular this week/month") ---------------
//
// The whole point is that this costs NO extra KV operation: the buckets ride
// along in the write the totals were already doing. If that ever stops being
// true, the write budget (1k/day, the tightest free-tier limit) is back in play.

const trendingReq = () => new Request("https://w.dev/trending");
const today = () => new Date().toISOString().slice(0, 10);

await test("/install records a day bucket without any extra KV write", async () => {
    installCacheMock();
    const e = { ...env(), INSTALL_COUNTS: makeKV({ "counts:all": JSON.stringify({ totals: { alpha: 5 }, days: {} }) }) };
    resetOps();
    await worker.fetch(installReq("alpha", "1.2.3.4"), e, ctx);
    const doc = JSON.parse(e.INSTALL_COUNTS._store.get("counts:all"));
    eq(doc.totals, { alpha: 6 }, "total bumped");
    eq(doc.days[today()], { alpha: 1 }, "day bucket bumped");
    eq(ops.put, 1, "still ONE kv write");
    eq(ops.get, 1, "still ONE kv read");
});

await test("day buckets accumulate across installs from different IPs", async () => {
    installCacheMock();
    const e = { ...env(), INSTALL_COUNTS: makeKV({ "counts:all": JSON.stringify({ totals: {}, days: {} }) }) };
    await worker.fetch(installReq("alpha", "1.1.1.1"), e, ctx);
    await worker.fetch(installReq("alpha", "2.2.2.2"), e, ctx);
    await worker.fetch(installReq("beta", "3.3.3.3"), e, ctx);
    const doc = JSON.parse(e.INSTALL_COUNTS._store.get("counts:all"));
    eq(doc.days[today()], { alpha: 2, beta: 1 }, "buckets");
    eq(doc.totals, { alpha: 2, beta: 1 }, "totals agree");
});

await test("a deduped install touches neither totals nor buckets", async () => {
    installCacheMock();
    const e = { ...env(), INSTALL_COUNTS: makeKV({ "counts:all": JSON.stringify({ totals: {}, days: {} }) }) };
    await worker.fetch(installReq("alpha", "9.9.9.9"), e, ctx);
    await worker.fetch(installReq("alpha", "9.9.9.9"), e, ctx);
    const doc = JSON.parse(e.INSTALL_COUNTS._store.get("counts:all"));
    eq(doc.totals, { alpha: 1 }, "one bump only");
    eq(doc.days[today()], { alpha: 1 }, "one bucket entry only");
});

await test("buckets older than the retention window are pruned on write", async () => {
    installCacheMock();
    const old = new Date(Date.now() - 60 * 86400000).toISOString().slice(0, 10);
    const recent = new Date(Date.now() - 3 * 86400000).toISOString().slice(0, 10);
    const e = { ...env(), INSTALL_COUNTS: makeKV({ "counts:all": JSON.stringify({
        totals: { alpha: 1 }, days: { [old]: { alpha: 1 }, [recent]: { alpha: 1 } } }) }) };
    await worker.fetch(installReq("alpha", "4.4.4.4"), e, ctx);
    const doc = JSON.parse(e.INSTALL_COUNTS._store.get("counts:all"));
    eq(doc.days[old], undefined, "60-day-old bucket dropped");
    eq(doc.days[recent], { alpha: 1 }, "3-day-old bucket kept");
});

await test("/counts response shape is unchanged for released clients", async () => {
    // Released plugin versions parse { ok, counts } and nothing else. The day
    // data must NOT leak into this payload.
    installCacheMock();
    const e = { ...env(), INSTALL_COUNTS: makeKV({ "counts:all": JSON.stringify({
        totals: { alpha: 5 }, days: { [today()]: { alpha: 2 } } }) }) };
    const body = await (await worker.fetch(countsReq(), e, ctx)).json();
    eq(Object.keys(body).sort(), ["counts", "ok"], "exactly ok+counts");
    eq(body.counts, { alpha: 5 }, "totals only");
});

await test("/counts still serves a flat legacy blob unchanged", async () => {
    // The shape shipped on 2026-08-23 must keep loading.
    installCacheMock();
    const e = { ...env(), INSTALL_COUNTS: makeKV({ "counts:all": JSON.stringify({ alpha: 5, beta: 3 }) }) };
    const body = await (await worker.fetch(countsReq(), e, ctx)).json();
    eq(body.counts, { alpha: 5, beta: 3 }, "flat blob read as totals");
});

await test("/install upgrades a flat legacy blob in place", async () => {
    installCacheMock();
    const e = { ...env(), INSTALL_COUNTS: makeKV({ "counts:all": JSON.stringify({ alpha: 5 }) }) };
    await worker.fetch(installReq("alpha", "5.5.5.5"), e, ctx);
    const doc = JSON.parse(e.INSTALL_COUNTS._store.get("counts:all"));
    eq(doc.totals, { alpha: 6 }, "totals carried over");
    eq(doc.days[today()], { alpha: 1 }, "day bucket started");
});

await test("/trending rolls up the windows and reports how much history backs them", async () => {
    installCacheMock();
    const d = (n) => new Date(Date.now() - n * 86400000).toISOString().slice(0, 10);
    const e = { ...env(), INSTALL_COUNTS: makeKV({ "counts:all": JSON.stringify({
        totals: { alpha: 100, beta: 100 },
        days: {
            [d(0)]:  { alpha: 5,  beta: 1 },
            [d(3)]:  { alpha: 3,  beta: 1 },
            [d(20)]: { alpha: 1,  beta: 50 },   // inside 30, outside 7
        } }) }) };
    resetOps();
    const body = await (await worker.fetch(trendingReq(), e, ctx)).json();
    eq(body.ok, true);
    eq(body.windows["7"],  { alpha: 8,  beta: 2 },  "7-day window excludes the 20-day-old bucket");
    eq(body.windows["30"], { alpha: 9,  beta: 52 }, "30-day window includes it");
    eq(body.days_recorded, 3, "history depth reported");
    eq(ops.get, 1, "one kv read");
    eq(ops.put, 0, "no writes");
});

await test("/trending on a namespace with no history yet returns empty windows", async () => {
    installCacheMock();
    const e = { ...env(), INSTALL_COUNTS: makeKV({ "counts:all": JSON.stringify({ totals: { alpha: 9 }, days: {} }) }) };
    const body = await (await worker.fetch(trendingReq(), e, ctx)).json();
    eq(body.windows["7"], {}, "no window data");
    eq(body.days_recorded, 0, "zero days recorded");
});

await test("/trending rejects non-GET", async () => {
    installCacheMock();
    const e = { ...env(), INSTALL_COUNTS: makeKV() };
    eq((await worker.fetch(new Request("https://w.dev/trending", { method: "POST" }), e, ctx)).status, 405);
});

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
