// Runs the pr-close-guard github-script against a mock octokit. Needs python + pyyaml: node tests/close_guard/run.js
const { execFileSync } = require('child_process');
const path = require('path');
const root = path.join(__dirname, '..', '..');
const script = JSON.parse(execFileSync(process.env.PYTHON || 'python', [path.join(__dirname, '..', 'milestone', 'extract.py'), path.join(root, '.github/workflows/pr-close-guard.yml'), '0']).toString());
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
function mock(st) {
  const calls = [];
  const rec = (n, f) => async (a) => { calls.push([n, a]); return f(a); };
  const github = {
    paginate: async (fn, args) => (await fn(args)).data,
    rest: {
      pulls: { get: async () => ({ data: st.pr }) },
      issues: {
        listComments: async () => ({ data: st.comments || [] }),
        listMilestones: async (a) => ({ data: st.ms.filter((m) => a.state === 'all' || m.state === a.state) }),
        createMilestone: rec('createMilestone', async (a) => { const m = { number: 50 + st.ms.length, title: a.title, state: 'open' }; st.ms.push(m); return { data: m }; }),
        updateMilestone: rec('updateMilestone', async () => ({ data: {} })),
        update: rec('update', async () => ({})),
        createLabel: rec('createLabel', async () => { if (st.labelExists) { const e = new Error('x'); e.status = 422; throw e; } return {}; }),
        addLabels: rec('addLabels', async () => ({})),
        create: rec('create', async (a) => { if (a.assignees && st.assigneeRefused) { const e = new Error('x'); e.status = 422; throw e; } return { data: { number: 99 } }; }),
        createComment: rec('createComment', async () => ({})),
      },
      repos: { listTags: async () => ({ data: (st.tags || []).map((name) => ({ name })) }) },
    },
  };
  const out = { failed: null, notices: [] };
  const core = { setFailed: (m) => { out.failed = m; }, notice: (m) => out.notices.push(m) };
  return { github, core, calls, out };
}
let pass = 0, fail = 0;
const ok = (c, name) => { if (c) pass++; else { fail++; console.log('FAIL', name); } };
const base = (o = {}) => ({ pr: { number: 7, state: 'closed', merged: false, merged_at: null, title: 'feat: x', html_url: 'u', user: { login: 'kim', type: 'User' }, head: { ref: 'dev-feat/1-x' }, labels: [], assignees: [{ login: 'kim' }], milestone: null, ...(o.pr || {}) }, ms: o.ms || [{ number: 1, title: '1.0.0', state: 'open' }], tags: o.tags || [], comments: o.comments, assigneeRefused: o.assigneeRefused, labelExists: o.labelExists });
async function run(st) { const m = mock(st); await new AsyncFunction('github', 'context', 'core', script)(m.github, { repo: { owner: 'o', repo: 'r' }, payload: { pull_request: { number: 7 } } }, m.core); return m; }
const names = (m) => m.calls.map((c) => c[0]);
(async () => {
  let m = await run(base());
  ok(names(m).includes('update') && m.calls.find((c) => c[0] === 'update')[1].milestone === 1, 'person: milestone assigned');
  ok(m.calls.find((c) => c[0] === 'addLabels')[1].labels[0] === 'status/redo', 'person: status/redo');
  const iss = m.calls.find((c) => c[0] === 'create')[1];
  ok(iss && iss.milestone === 1 && iss.labels.includes('type/chore') && iss.labels.includes('P4') && iss.assignees[0] === 'kim', 'person: redo issue in milestone with default labels');
  ok(names(m).includes('createComment'), 'person: comment');
  m = await run(base({ pr: { user: { login: 'dependabot[bot]', type: 'Bot' }, milestone: { number: 1, title: '1.0.0' } } }));
  ok(m.calls.find((c) => c[0] === 'addLabels')[1].labels[0] === 'status/dropped' && !names(m).includes('create') && !names(m).includes('update'), 'bot: dropped, no issue, milestone kept');
  m = await run(base({ pr: { head: { ref: 'dev' } } }));
  ok(m.calls.find((c) => c[0] === 'addLabels')[1].labels[0] === 'status/dropped' && !names(m).includes('create'), 'promotion PR: dropped');
  m = await run(base({ pr: { labels: ['status/superseded'], milestone: { number: 1, title: '1.0.0' } } }));
  ok(!names(m).includes('addLabels') && !names(m).includes('create') && names(m).includes('createComment'), 'existing status label kept');
  m = await run(base({ pr: { merged: true, merged_at: 'x' } }));
  ok(m.calls.length === 0, 'merged: nothing');
  m = await run(base({ comments: [{ body: '<!-- pr-close-guard -->\nx' }] }));
  ok(m.calls.length === 0, 'marker: idempotent');
  m = await run(base({ ms: [], tags: ['1.3.18', 'v1.3.2'] }));
  ok(m.calls.find((c) => c[0] === 'createMilestone')[1].title === '1.3.19', 'no open milestone: next patch of newest tag');
  m = await run(base({ ms: [{ number: 3, title: '2.0.0', state: 'open' }, { number: 2, title: '1.5.0', state: 'open' }, { number: 9, title: 'Backlog', state: 'open' }] }));
  ok(m.calls.find((c) => c[0] === 'update')[1].milestone === 2, 'lowest open VERSION milestone');
  m = await run(base({ assigneeRefused: true }));
  ok(m.calls.filter((c) => c[0] === 'create').length === 2 && !m.calls.filter((c) => c[0] === 'create')[1][1].assignees, 'refused assignee: retried unassigned');
  m = await run(base({ labelExists: true }));
  ok(names(m).includes('addLabels'), 'label already exists (422) tolerated');
  m = await run(base({ pr: { state: 'open' } }));
  ok(m.calls.length === 0, 'reopened: nothing');
  console.log(`pr-close-guard: ${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
