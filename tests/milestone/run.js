// Extracts the github-script bodies from the workflow YAML (via extract.py JSON) and runs them with a mock octokit.
const { execFileSync } = require('child_process');
const path = require('path');
const root = path.join(__dirname, '..', '..');   // repo root; run: node tests/milestone/run.js (needs python + pyyaml)
const wf = (org, f) => JSON.parse(execFileSync('python', [path.join(__dirname, 'extract.py'), path.join(root, '.github/workflows', f)]).toString());
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;

function mock(state) {
  const calls = [];
  const rec = (n, f) => async (a) => { calls.push([n, a]); return f(a); };
  const github = {
    paginate: async (fn, args, map) => { const r = await fn(args); return map ? map(r) : r.data; },
    rest: {
      pulls: { get: rec('pulls.get', async (a) => { if (!state.prs[a.pull_number]) { const e = new Error('nf'); e.status = 404; throw e; } return { data: state.prs[a.pull_number] }; }) },
      issues: {
        listMilestones: async (a) => ({ data: state.ms.filter((m) => a.state === 'all' || m.state === a.state) }),
        createMilestone: rec('createMilestone', async (a) => { if (state.ms.some((m) => m.title === a.title)) { const e = new Error('exists'); e.status = 422; throw e; } const m = { number: 100 + state.ms.length, title: a.title, state: 'open', html_url: 'u/' + a.title }; state.ms.push(m); return { data: m }; }),
        updateMilestone: rec('updateMilestone', async (a) => { const m = state.ms.find((x) => x.number === a.milestone_number); for (const k of ['state', 'due_on', 'description']) if (a[k] !== undefined) m[k] = a[k]; return { data: m }; }),
        update: rec('issues.update', async (a) => { if (state.prs && state.prs[a.issue_number] && !state.denyUpdate) state.prs[a.issue_number].milestone = { number: a.milestone, title: 'assigned' }; if (state.denyUpdate) { const e = new Error('forbidden'); e.status = 403; throw e; } return {}; }),
      },
      repos: {
        listTags: async () => ({ data: state.tags.map((name) => ({ name })) }),
        compareCommitsWithBasehead: async (a) => ({ data: { status: (state.diverged || []).includes(a.basehead.split('...')[0]) ? 'diverged' : 'ahead', commits: state.commits } }),
        listCommits: async () => ({ data: state.commits }),
        listPullRequestsAssociatedWithCommit: rec('assoc', async (a) => ({ data: ((state.assocMap || {})[a.commit_sha] || []).map((number) => ({ number })) })),
        getReleaseByTag: async () => { if (state.release) return { data: state.release }; const e = new Error('nf'); e.status = 404; throw e; },
        updateRelease: rec('updateRelease', async () => ({})),
      },
    },
  };
  const out = { failed: null, notices: [] };
  const core = { setFailed: (m) => { out.failed = m; }, notice: (m) => out.notices.push(m), warning: () => {}, summary: { addRaw() { return this; }, async write() {} } };
  return { github, core, calls, out };
}

let pass = 0, fail = 0;
const ok = (c, name) => { if (c) pass++; else { fail++; console.log('FAIL', name); } };

async function runPr(org, mode, state, prNum = 7) {
  const s = wf(org, 'pr-milestone.yml');
  process.env.MODE = mode;
  const m = mock(state);
  const ctx = { repo: { owner: 'o', repo: 'r' }, payload: { pull_request: { number: prNum } }, eventName: 'pull_request' };
  await new AsyncFunction('github', 'context', 'core', s)(m.github, ctx, m.core);
  return m;
}
async function runRel(org, tag, state, dry = false, release = null) {
  const s = wf(org, 'release-milestone.yml');
  process.env.IN_TAG = tag; process.env.DRY = String(dry); process.env.APPEND = 'true';
  const m = mock(state);
  const ctx = { repo: { owner: 'o', repo: 'r' }, payload: release ? { release } : {}, ref: '' };
  await new AsyncFunction('github', 'context', 'core', s)(m.github, ctx, m.core);
  return m;
}
const pr = (milestone) => ({ 7: { number: 7, milestone } });
const M = (number, title, state = 'open') => ({ number, title, state, html_url: 'u/' + title });

(async () => {
  for (const org of ['this-org']) {
    let m;
    // enforce
    m = await runPr(org, 'enforce', { prs: pr(null), ms: [], tags: [] }); ok(m.out.failed && /no milestone/.test(m.out.failed), org + ' enforce missing fails');
    m = await runPr(org, 'enforce', { prs: pr(M(1, '1.3.18')), ms: [], tags: [] }); ok(!m.out.failed, org + ' enforce version passes');
    m = await runPr(org, 'enforce', { prs: pr(M(1, 'v1.3.18-rc.1')), ms: [], tags: [] }); ok(!m.out.failed, org + ' v+prerelease passes');
    m = await runPr(org, 'enforce', { prs: pr(M(1, 'Sprint 5')), ms: [], tags: [] }); ok(m.out.failed && /not a version/.test(m.out.failed), org + ' non-version fails');
    for (const bad of ['1.2.3-01', '1.3', '01.2.3', '1.2.3.4', 'latest', '1.3.18-build.N!', '']) { m = await runPr(org, 'enforce', { prs: pr(M(1, bad)), ms: [], tags: [] }); ok(m.out.failed, org + ' bad title ' + bad); }
    m = await runPr(org, 'assign', { prs: pr(M(1, 'Sprint 5')), ms: [], tags: [] }); ok(m.out.failed, org + ' assign still fails non-version');
    m = await runPr(org, 'bogus', { prs: pr(null), ms: [], tags: [] }); ok(m.out.failed && /unknown mode/.test(m.out.failed), org + ' bad mode');
    m = await runPr(org, 'assign', { prs: pr(null), ms: [M(1, '1.2.3-9007199254740993'), M(2, '1.2.3-9007199254740992')], tags: [] }); ok(m.calls.find((c) => c[0] === 'issues.update')[1].milestone === 2, org + ' bigint prerelease compare');
    m = await runPr(org, 'assign', { prs: pr(null), ms: [M(1, '1.2.3-rc.10'), M(2, '1.2.3-rc.9'), M(3, '1.2.3')], tags: [] }); ok(m.calls.find((c) => c[0] === 'issues.update')[1].milestone === 2, org + ' prerelease order');
    // assign: lowest open
    const st = { prs: pr(null), ms: [M(1, '1.10.0'), M(2, '1.9.2'), M(3, 'misc'), M(4, '1.9.10'), M(5, '1.0.0', 'closed')], tags: [] };
    m = await runPr(org, 'assign', st); const u = m.calls.find((c) => c[0] === 'issues.update');
    ok(!m.out.failed && u && u[1].milestone === 2, org + ' assign lowest open (1.9.2) got ' + (u && u[1].milestone));
    // assign: none open -> next patch of newest tag
    m = await runPr(org, 'assign', { prs: pr(null), ms: [], tags: ['v1.2.9', 'v1.2.10', '1.1.0', 'junk', 'v1.2.10-rc.1'] });
    const cm = m.calls.find((c) => c[0] === 'createMilestone'); ok(cm && cm[1].title === '1.2.11', org + ' next patch 1.2.11 got ' + (cm && cm[1].title));
    m = await runPr(org, 'assign', { prs: pr(null), ms: [], tags: [] }); ok(m.calls.find((c) => c[0] === 'createMilestone')[1].title === '0.0.1', org + ' no tags -> 0.0.1');
    m = await runPr(org, 'assign', { prs: pr(null), ms: [], tags: ['v2.0.0-rc.1'] }); ok(m.calls.find((c) => c[0] === 'createMilestone')[1].title === '2.0.0', org + ' prerelease tag -> 2.0.0');
    // closed milestone with the name exists -> reopen
    m = await runPr(org, 'assign', { prs: pr(null), ms: [M(9, '1.2.4', 'closed')], tags: ['v1.2.3'] }); ok(m.calls.some((c) => c[0] === 'updateMilestone' && c[1].state === 'open') && !m.out.failed, org + ' reopen closed');
    m = await runPr(org, 'assign', { prs: pr(null), ms: [M(1, '1.0.0')], tags: [], denyUpdate: true }); ok(m.out.failed && /could not assign/.test(m.out.failed), org + ' 403 fails clearly');

    // release
    const commits = [{ sha: 'a', commit: { message: 'feat: x (#11)\n\nbody' } }, { sha: 'b', commit: { message: 'Merge pull request #12 from o/dev-fix/x' } }, { sha: 'c', commit: { message: 'plain commit' } }, { sha: 'd', commit: { message: 'fix: y (#13)' } }, { sha: 'e', commit: { message: 'fix: z (#14)' } }];
    const rs = () => ({ prs: { 11: { number: 11, merged_at: 't', merge_commit_sha: 'a', milestone: null }, 12: { number: 12, merged_at: 't', merge_commit_sha: 'b', milestone: M(5, '1.3.0') }, 13: { number: 13, merged_at: null, milestone: null }, 15: { number: 15, merged_at: 't', merge_commit_sha: 'c', milestone: null } }, ms: [M(7, '1.3.1')], tags: ['v1.3.0', 'v1.3.1', 'v1.2.9', 'v1.3.2-rc.1'], commits, assocMap: { a: [11], b: [12], c: [15], d: [13] } });
    let rs1 = rs(); rs1.release = { id: 5, tag_name: 'v1.3.1', body: 'notes', published_at: '2026-11-02T20:15:00Z', html_url: 'https://github.com/o/r/releases/tag/v1.3.1' };
    m = await runRel(org, 'v1.3.1', rs1, false);
    const asg = m.calls.filter((c) => c[0] === 'issues.update').map((c) => c[1].issue_number).sort();
    ok(JSON.stringify(asg) === '[11,15]', org + ' assigns only un-milestoned merged: ' + asg);
    ok(m.calls.some((c) => c[0] === 'updateMilestone' && c[1].state === 'closed'), org + ' closes 1.3.1');
    ok(m.calls.some((c) => c[0] === 'createMilestone' && c[1].title === '1.3.2'), org + ' opens 1.3.2');
    const ur = m.calls.find((c) => c[0] === 'updateRelease'); ok(ur && /Milestone: u\/1\.3\.1/.test(ur[1].body), org + ' release link appended');
    ok(m.out.notices.some((n) => /prev=v1\.3\.0/.test(n)), org + ' prev tag is v1.3.0');
    // idempotent: run twice on the SAME state (assignments persist in the mock)
    const s2 = rs(); s2.release = { id: 5, tag_name: 'v1.3.1', body: 'x', published_at: '2026-11-02T20:15:00Z', html_url: 'https://github.com/o/r/releases/tag/v1.3.1' };
    await runRel(org, 'v1.3.1', s2, false);
    s2.release.body = 'x\n\nMilestone: https://github.com/o/r/milestone/7';
    s2.ms.forEach((x) => { if (x.title === '1.3.1') x.state = 'closed'; });
    m = await runRel(org, 'v1.3.1', s2, false);
    ok(!m.calls.some((c) => ['updateRelease', 'createMilestone', 'updateMilestone', 'issues.update'].includes(c[0])), org + ' idempotent second run: ' + m.calls.map((c) => c[0]));
    const s5 = rs(); s5.ms = [M(7, '1.3.1'), M(8, '1.3.2', 'closed')];
    m = await runRel(org, 'v1.3.1', s5, false); ok(m.calls.some((c) => c[0] === 'updateMilestone' && c[1].milestone_number === 8 && c[1].state === 'open'), org + ' reopens closed next');
    const s6 = rs(); s6.diverged = ['v1.3.0', 'v1.2.9'];
    m = await runRel(org, 'v1.3.1', s6, false); ok(m.out.failed && !m.calls.some((c) => ['issues.update', 'createMilestone', 'updateMilestone'].includes(c[0])), org + ' no ancestor fails clean');
    const s7 = rs(); s7.commits = Array.from({ length: 501 }, (_, i) => ({ sha: 'x' + i, commit: { message: 'm' } }));
    m = await runRel(org, 'v1.3.1', s7, false); ok(m.out.failed && !m.calls.some((c) => ['issues.update', 'updateMilestone'].includes(c[0])), org + ' >500 commits fails clean');
    const s8 = rs(); s8.commits = [{ sha: 'z', commit: { message: 'x (#11)' } }]; s8.assocMap = { z: [12] }; s8.prs[12].milestone = null; s8.prs[12].merge_commit_sha = 'z';
    m = await runRel(org, 'v1.3.1', s8, false); ok(JSON.stringify(m.calls.filter((c) => c[0] === 'issues.update').map((c) => c[1].issue_number)) === '[12]', org + ' uses association not message');
    const s9 = rs(); s9.prs[15].merge_commit_sha = 'outside';
    m = await runRel(org, 'v1.3.1', s9, false); ok(!m.calls.some((c) => c[0] === 'issues.update' && c[1].issue_number === 15), org + ' outside-range PR skipped');
    const s10 = rs(); s10.ms = [M(7, '1.3.1', 'closed'), M(8, '1.3.2', 'closed')]; s10.tags.push('v1.3.2');
    m = await runRel(org, 'v1.3.1', s10, false); ok(!m.calls.some((c) => c[0] === 'updateMilestone' && c[1].state === 'open'), org + ' old rerun does not reopen successor');
    const s11 = rs(); s11.tags = ['v1.3.1']; for (let i = 0; i < 10; i++) s11.tags.push('v1.2.' + (20 + i)); s11.tags.push('v1.0.0'); s11.diverged = s11.tags.filter((t) => /^v1\.2\./.test(t));
    m = await runRel(org, 'v1.3.1', s11, false); ok(!m.out.failed && m.out.notices.some((n) => /prev=v1\.0\.0/.test(n)), org + ' deep ancestor found');
    // dry run writes nothing
    let rs4 = rs(); rs4.release = { id: 5, tag_name: 'v1.3.1', body: 'n' };
    m = await runRel(org, 'v1.3.1', rs4, true);
    ok(!m.calls.some((c) => ['updateRelease', 'createMilestone', 'updateMilestone', 'issues.update'].includes(c[0])), org + ' dry run writes nothing');
    // prerelease: assign but no close/next
    const s3 = rs(); s3.ms = [];
    m = await runRel(org, 'v1.3.2-rc.2', s3, false, null);
    ok(m.calls.some((c) => c[0] === 'issues.update') && !m.calls.some((c) => c[0] === 'updateMilestone') && m.calls.filter((c) => c[0] === 'createMilestone').length === 1, org + ' prerelease no close/next');
    // release date on the milestone (Kim 2026-11-02): due_on = Pacific date at 12:00Z, description line 1 = "Released YYYY-MM-DD HH:MM PT - <url>"
    const closeCall = (mm) => mm.calls.find((c) => c[0] === 'updateMilestone' && c[1].state === 'closed');
    const REL = (at, extra = {}) => Object.assign({ id: 5, tag_name: 'v1.3.1', body: 'n', published_at: at, html_url: 'https://github.com/o/r/releases/tag/v1.3.1' }, extra);
    let d1 = rs(); d1.release = REL('2026-11-02T20:15:00Z');
    m = await runRel(org, 'v1.3.1', d1, false, d1.release);
    let cc = closeCall(m);
    ok(cc && cc[1].due_on === '2026-11-02T12:00:00Z', org + ' due_on is the Pacific date at 12:00Z: ' + (cc && cc[1].due_on));
    ok(cc && cc[1].description === 'Released 2026-11-02 12:15 PT - https://github.com/o/r/releases/tag/v1.3.1', org + ' description line 1: ' + (cc && cc[1].description));
    ok(d1.ms.find((x) => x.title === '1.3.1').state === 'closed', org + ' milestone closed');
    // UTC date differs from the Pacific date (03:30Z on the 3rd = 19:30 PST on the 2nd)
    d1 = rs(); d1.release = REL('2026-11-03T03:30:00Z');
    cc = closeCall(await runRel(org, 'v1.3.1', d1, false)); ok(cc && cc[1].due_on === '2026-11-02T12:00:00Z' && /^Released 2026-11-02 19:30 PT - /.test(cc[1].description), org + ' pacific date, not UTC date');
    // daylight saving: 06:59Z on 1 July = 23:59 PDT on 30 June
    d1 = rs(); d1.release = REL('2026-07-01T06:59:00Z');
    cc = closeCall(await runRel(org, 'v1.3.1', d1, false)); ok(cc && cc[1].due_on === '2026-06-30T12:00:00Z' && /^Released 2026-06-30 23:59 PT - /.test(cc[1].description), org + ' PDT date');
    // milestone missing: created, then closed with the date
    d1 = rs(); d1.ms = []; d1.release = REL('2026-11-02T20:15:00Z');
    m = await runRel(org, 'v1.3.1', d1, false);
    cc = closeCall(m); ok(m.calls.some((c) => c[0] === 'createMilestone' && c[1].title === '1.3.1') && cc && cc[1].due_on === '2026-11-02T12:00:00Z', org + ' missing milestone created then closed with date');
    // existing description kept below the Released line; an older Released line is replaced, not stacked
    d1 = rs(); d1.release = REL('2026-11-02T20:15:00Z'); d1.ms[0].description = 'Released 2026-01-01 00:00 PT - old\nScope: the thing';
    cc = closeCall(await runRel(org, 'v1.3.1', d1, false)); ok(cc && cc[1].description === 'Released 2026-11-02 12:15 PT - https://github.com/o/r/releases/tag/v1.3.1\nScope: the thing', org + ' description kept, old Released line replaced');
    // idempotent: a second run with the same release writes nothing; a closed milestone with no date gets one
    m = await runRel(org, 'v1.3.1', d1, false);
    ok(!m.calls.some((c) => c[0] === 'updateMilestone'), org + ' second run does not touch the milestone: ' + m.calls.map((c) => c[0]));
    d1 = rs(); d1.release = REL('2026-11-02T20:15:00Z'); d1.ms[0].state = 'closed';
    cc = closeCall(await runRel(org, 'v1.3.1', d1, false)); ok(cc && cc[1].due_on === '2026-11-02T12:00:00Z', org + ' closed-but-undated milestone gets the date');
    // no release object at all (tag push): falls back to the last commit date, else now; url is the tag URL
    d1 = rs(); d1.commits = commits.map((c, i) => i === commits.length - 1 ? Object.assign({}, c, { commit: { message: c.commit.message, committer: { date: '2026-10-30T01:00:00Z' } } }) : c);
    cc = closeCall(await runRel(org, 'v1.3.1', d1, false)); ok(cc && cc[1].due_on === '2026-10-29T12:00:00Z' && /^Released 2026-10-29 18:00 PT - https:\/\/github\.com\/o\/r\/releases\/tag\/v1\.3\.1$/.test(cc[1].description), org + ' fallback to commit date');
    // wrong existing due date is corrected even when the header line is right
    d1 = rs(); d1.release = REL('2026-11-02T20:15:00Z'); d1.ms[0].state = 'closed'; d1.ms[0].due_on = '2030-01-01T12:00:00Z'; d1.ms[0].description = 'Released 2026-11-02 12:15 PT - https://github.com/o/r/releases/tag/v1.3.1';
    cc = closeCall(await runRel(org, 'v1.3.1', d1, false)); ok(cc && cc[1].due_on === '2026-11-02T12:00:00Z', org + ' wrong due_on is corrected');
    // ordinary prose that starts with "Released" is kept verbatim (indent too); only the generated header line is ever replaced
    d1 = rs(); d1.release = REL('2026-11-02T20:15:00Z'); d1.ms[0].description = 'Released components include the API and UI.\n  Indented scope';
    cc = closeCall(await runRel(org, 'v1.3.1', d1, false)); ok(cc && cc[1].description === 'Released 2026-11-02 12:15 PT - https://github.com/o/r/releases/tag/v1.3.1\nReleased components include the API and UI.\n  Indented scope', org + ' prose starting with Released kept verbatim');
    // Pacific midnight and the autumn DST change (2026-11-01 02:00 PDT -> 01:00 PST)
    for (const [iso, want] of [['2026-11-02T08:00:00Z', '2026-11-02 00:00'], ['2026-11-02T07:59:59Z', '2026-11-01 23:59'], ['2026-11-01T08:59:00Z', '2026-11-01 01:59'], ['2026-11-01T09:00:00Z', '2026-11-01 01:00'], ['2026-03-08T09:59:00Z', '2026-03-08 01:59'], ['2026-03-08T10:00:00Z', '2026-03-08 03:00']]) {
      d1 = rs(); d1.release = REL(iso); cc = closeCall(await runRel(org, 'v1.3.1', d1, false));
      ok(cc && cc[1].description.startsWith('Released ' + want + ' PT - ') && cc[1].due_on === want.slice(0, 10) + 'T12:00:00Z', org + ' pacific ' + iso + ' -> ' + (cc && cc[1].description.slice(0, 26)));
    }
    // the payload release wins over the API release for the same tag; a payload for ANOTHER tag is ignored
    d1 = rs(); d1.release = REL('2026-11-05T20:00:00Z'); m = await runRel(org, 'v1.3.1', d1, false, REL('2026-11-02T20:15:00Z'));
    cc = closeCall(m); ok(cc && cc[1].due_on === '2026-11-02T12:00:00Z', org + ' payload release wins');
    d1 = rs(); d1.release = REL('2026-11-05T20:00:00Z'); m = await runRel(org, 'v1.3.1', d1, false, REL('2026-11-02T20:15:00Z', { tag_name: 'v9.9.9' }));
    cc = closeCall(m); ok(cc && cc[1].due_on === '2026-11-05T12:00:00Z', org + ' payload for another tag ignored');
    // no timestamp anywhere: stamped with now once, and a re-run never rewrites that header
    d1 = rs(); m = await runRel(org, 'v1.3.1', d1, false); ok(!!closeCall(m), org + ' no-timestamp first run stamps');
    m = await runRel(org, 'v1.3.1', d1, false); ok(!m.calls.some((c) => c[0] === 'updateMilestone'), org + ' no-timestamp re-run is a no-op');
    // pre-release and dry run never stamp
    d1 = rs(); d1.ms = []; m = await runRel(org, 'v1.3.2-rc.2', d1, false);
    ok(!m.calls.some((c) => c[0] === 'updateMilestone'), org + ' pre-release: no date stamp, no close');
    d1 = rs(); d1.release = REL('2026-11-02T20:15:00Z'); m = await runRel(org, 'v1.3.1', d1, true);
    ok(!m.calls.some((c) => c[0] === 'updateMilestone'), org + ' dry run: no date stamp');
    // non-version tag
    m = await runRel(org, 'nightly', rs()); ok(m.calls.length === 0 && !m.out.failed, org + ' non-version tag no-op');
  }
  console.log(`pass=${pass} fail=${fail}`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
