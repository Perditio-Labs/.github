// Runs the pr-close-guard github-script against a stateful mock octokit. Needs python + pyyaml: node tests/close_guard/run.js
const { execFileSync } = require('child_process');
const path = require('path');
const root = path.join(__dirname, '..', '..');
const script = JSON.parse(execFileSync(process.env.PYTHON || 'python', [path.join(__dirname, '..', 'milestone', 'extract.py'), path.join(root, '.github/workflows/pr-close-guard.yml'), '0']).toString());
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
function httpError(status) { const e = new Error('http ' + status); e.status = status; return e; }
function mock(st) {
  const calls = [];
  const rec = (n, f) => async (a) => { calls.push([n, a]); return f(a); };
  const github = {
    paginate: async (fn, args) => (await fn(args)).data,
    rest: {
      pulls: { get: async () => ({ data: st.pr }) },
      issues: {
        listComments: async () => ({ data: st.comments || [] }),
        listForRepo: async () => ({ data: st.issues || [] }),
        listMilestones: async (a) => ({ data: st.ms.filter((m) => a.state === 'all' || m.state === a.state) }),
        createMilestone: rec('createMilestone', async (a) => { const m = { number: 50 + st.ms.length, title: a.title, state: 'open' }; st.ms.push(m); return { data: m }; }),
        updateMilestone: rec('updateMilestone', async () => { if (st.reopenFails) throw httpError(403); return { data: {} }; }),
        update: rec('update', async (a) => { if (st.updateFails) throw httpError(500); st.pr.milestone = st.ms.find((m) => m.number === a.milestone); return {}; }),
        createLabel: rec('createLabel', async () => { if (st.labelExists) throw httpError(422); return {}; }),
        addLabels: rec('addLabels', async (a) => { if (st.addLabelsFails) throw httpError(500); st.pr.labels = (st.pr.labels || []).concat(a.labels); return {}; }),
        create: rec('create', async (a) => {
          if (a.assignees && st.assigneeRefused) throw httpError(422);
          if (st.createFails) throw httpError(500);
          const issue = { number: 99, user: { type: 'Bot' }, body: a.body };
          st.issues = (st.issues || []).concat([issue]);
          return { data: issue };
        }),
        createComment: rec('createComment', async () => ({})),
        updateComment: rec('updateComment', async () => ({})),
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
const repoFull = { full_name: 'o/r' };
const base = (o = {}) => ({
  pr: { number: 7, state: 'closed', merged: false, merged_at: null, title: 'feat: x', html_url: 'u', user: { login: 'kim', type: 'User' },
        head: { ref: 'dev-feat/1-x', repo: repoFull }, base: { ref: 'dev', repo: repoFull }, labels: [], assignees: [{ login: 'kim' }], milestone: null, ...(o.pr || {}) },
  ms: o.ms || [{ number: 1, title: '1.0.0', state: 'open' }], tags: o.tags || [], comments: o.comments, issues: o.issues,
  assigneeRefused: o.assigneeRefused, labelExists: o.labelExists, createFails: o.createFails, reopenFails: o.reopenFails, updateFails: o.updateFails, addLabelsFails: o.addLabelsFails,
});
async function run(st) {
  const m = mock(st);
  try { await new AsyncFunction('github', 'context', 'core', script)(m.github, { repo: { owner: 'o', repo: 'r' }, payload: { pull_request: { number: 7 } } }, m.core); }
  catch (e) { m.threw = e; }
  return m;
}
const names = (m) => m.calls.map((c) => c[0]);
const labelsAdded = (m) => m.calls.filter((c) => c[0] === 'addLabels').map((c) => c[1].labels[0]);
const MARK = '<!-- pr-close-guard -->';
(async () => {
  let m = await run(base());
  ok(m.calls.find((c) => c[0] === 'update')[1].milestone === 1, 'person: milestone assigned');
  ok(labelsAdded(m)[0] === 'status/redo', 'person: status/redo');
  const iss = m.calls.find((c) => c[0] === 'create')[1];
  ok(iss && iss.milestone === 1 && iss.labels.includes('type/chore') && iss.labels.includes('P4') && iss.assignees[0] === 'kim', 'person: redo issue in milestone with default labels');
  ok(names(m).indexOf('create') < names(m).indexOf('addLabels'), 'redo issue is created BEFORE the status/redo label');
  ok(names(m).includes('createComment'), 'person: comment');

  m = await run(base({ pr: { user: { login: 'dependabot[bot]', type: 'Bot' }, milestone: { number: 1, title: '1.0.0' } } }));
  ok(labelsAdded(m)[0] === 'status/dropped' && !names(m).includes('create') && !names(m).includes('update'), 'bot: dropped, no issue, milestone kept');
  m = await run(base({ pr: { head: { ref: 'dev', repo: repoFull }, base: { ref: 'staging', repo: repoFull } } }));
  ok(labelsAdded(m)[0] === 'status/dropped' && !names(m).includes('create'), 'same-repo promotion dev->staging: dropped');
  m = await run(base({ pr: { user: { login: 'renovate-human', type: 'User' } } }));
  ok(labelsAdded(m)[0] === 'status/redo', 'login prefix alone is not a bot');
  m = await run(base({ pr: { head: { ref: 'main', repo: { full_name: 'fork/r' } }, base: { ref: 'dev', repo: repoFull } } }));
  ok(labelsAdded(m)[0] === 'status/redo', 'fork branch named main is not a promotion');
  m = await run(base({ pr: { head: { ref: 'main', repo: repoFull }, base: { ref: 'dev', repo: repoFull } } }));
  ok(labelsAdded(m)[0] === 'status/redo', 'ordinary branch named main into dev is not a promotion');

  m = await run(base({ pr: { labels: ['status/superseded'] } }));
  ok(names(m).includes('update') && !names(m).includes('addLabels') && !names(m).includes('create') && names(m).includes('createComment'), 'status/superseded: milestone repaired, label kept, no issue');
  m = await run(base({ pr: { merged: true, merged_at: 'x' } }));
  ok(m.calls.length === 0, 'merged: nothing');
  m = await run(base({ pr: { state: 'open' } }));
  ok(m.calls.length === 0, 'reopened: nothing');

  // R1-1: forged marker by a person does not suppress; genuine bot marker is updated in place and still reconciles
  m = await run(base({ comments: [{ id: 5, user: { type: 'User', login: 'mallory' }, body: MARK + '\nforged' }] }));
  ok(names(m).includes('update') && labelsAdded(m)[0] === 'status/redo' && names(m).includes('createComment') && !names(m).includes('updateComment'), 'forged marker does not suppress the guard');
  m = await run(base({ comments: [{ id: 5, user: { type: 'Bot', login: 'github-actions[bot]' }, body: MARK + '\nold' }] }));
  ok(names(m).includes('update') && names(m).includes('updateComment') && !names(m).includes('createComment'), 'reopen+reclose with metadata removed: repaired, comment updated in place');

  // R1-2: partial failures
  m = await run(base({ createFails: true }));
  ok(m.threw && !names(m).includes('addLabels'), 'issue create fails: no status/redo label left behind');
  m = await run(base({ pr: { labels: ['status/redo'], milestone: { number: 1, title: '1.0.0' } } }));
  ok(names(m).includes('create') && !names(m).includes('addLabels'), 'status/redo label but no issue: issue created');
  m = await run(base({ pr: { labels: [], milestone: { number: 1, title: '1.0.0' } }, issues: [{ number: 42, user: { type: 'Bot' }, body: 'x\n<!-- redo-of-pr-7 -->' }] }));
  ok(!names(m).includes('create') && labelsAdded(m)[0] === 'status/redo', 'issue exists, label missing: no duplicate issue, label added');
  m = await run(base({ pr: { milestone: { number: 1, title: '1.0.0' } }, issues: [{ number: 43, user: { type: 'User', login: 'mallory' }, author_association: 'NONE', body: '<!-- redo-of-pr-7 -->' }] }));
  ok(names(m).includes('create'), 'untrusted issue with the marker is ignored');

  // R1-3: milestone ordering matches pr-milestone
  m = await run(base({ ms: [{ number: 10, title: '1.0.0-rc.10', state: 'open' }, { number: 2, title: '1.0.0-rc.2', state: 'open' }] }));
  ok(m.calls.find((c) => c[0] === 'update')[1].milestone === 2, 'rc.2 sorts before rc.10');
  m = await run(base({ ms: [{ number: 3, title: '2.0.0', state: 'open' }, { number: 2, title: '1.5.0', state: 'open' }, { number: 9, title: 'Backlog', state: 'open' }, { number: 8, title: '1.0.0-01', state: 'open' }] }));
  ok(m.calls.find((c) => c[0] === 'update')[1].milestone === 2, 'lowest valid VERSION milestone (invalid prerelease ignored)');
  m = await run(base({ ms: [], tags: ['1.3.18', 'v1.3.2'] }));
  ok(m.calls.find((c) => c[0] === 'createMilestone')[1].title === '1.3.19', 'no open milestone: next patch of newest tag');

  m = await run(base({ assigneeRefused: true }));
  ok(m.calls.filter((c) => c[0] === 'create').length === 2 && !m.calls.filter((c) => c[0] === 'create')[1][1].assignees, 'refused assignee: retried unassigned');
  m = await run(base({ labelExists: true }));
  ok(labelsAdded(m)[0] === 'status/redo', 'label already exists (422) tolerated');
  m = await run(base({ updateFails: true }));
  ok(m.threw && !names(m).includes('addLabels'), 'milestone write fails: nothing else written');

  // R1-6: no runner override input
  ok(!/runs_on/.test(require('fs').readFileSync(path.join(root, '.github/workflows/pr-close-guard.yml'), 'utf8')), 'no runs_on input');
  console.log(`pr-close-guard: ${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
