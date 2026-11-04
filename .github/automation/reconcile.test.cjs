const { test } = require('node:test');
const assert = require('node:assert/strict');
const reconcile = require('./reconcile.cjs');
const { validationName } = require('./policy.cjs');

const head = 'a'.repeat(40);
const base = 'b'.repeat(40);

function harness({ files = [{ filename: 'docs/guide.md', status: 'modified' }],
  reviews = [], jobs = ['automation-tests', 'analyze-test', 'windows-build'],
  hasRun = true, runStatus = 'completed', jobFailures = [], changedHead = false, incompleteFiles = false } = {}) {
  const calls = { statuses: [], approvals: [], dispatches: [], merges: [], failed: [] };
  let reads = 0;
  const pr = { number: 1, node_id: 'PR_1', head: { sha: head }, user: { login: 'author' },
    state: 'open', draft: false, changed_files: files.length + (incompleteFiles ? 1 : 0), auto_merge: null };
  const listPulls = () => {};
  const listRuns = () => {};
  const listFiles = () => {};
  const listReviews = () => {};
  const listJobs = () => {};
  const github = {
    rest: {
      repos: {
        get: async () => ({ data: { default_branch: 'main', allow_auto_merge: true } }),
        getBranch: async () => ({ data: { commit: { sha: base } } }),
        createCommitStatus: async data => { calls.statuses.push(data); },
        getCollaboratorPermissionLevel: async () => ({ data: { permission: 'write' } }),
      },
      pulls: {
        list: listPulls, listFiles, listReviews,
        get: async () => ({ data: ++reads > 1 && changedHead ? { ...pr, head: { sha: 'c'.repeat(40) } } : pr }),
        createReview: async data => { calls.approvals.push(data); },
      },
      actions: {
        listWorkflowRuns: listRuns, listJobsForWorkflowRun: listJobs,
        createWorkflowDispatch: async data => { calls.dispatches.push(data); },
      },
    },
    paginate: async method => {
      if (method === listPulls) return [pr];
      if (method === listFiles) return files;
      if (method === listReviews) return reviews;
      if (method === listRuns) return hasRun ? [{ id: 1, display_title: validationName(1, head, base),
        head_branch: 'main', status: runStatus, conclusion: runStatus === 'completed' ? 'success' : null, html_url: 'https://example.invalid/run/1' }] : [];
      if (method === listJobs) return jobs.map(name => ({ name, conclusion: jobFailures.includes(name) ? 'failure' : 'success' }));
      throw new Error('Unexpected API call');
    },
    graphql: async (query, variables) => { calls.merges.push({ query, variables }); },
  };
  const core = { info() {}, error() {}, setFailed: message => calls.failed.push(message) };
  return { calls, run: () => reconcile({ github, core, context: { repo: { owner: 'owner', repo: 'repo' } } }) };
}

test('controller approves docs only after real required jobs pass on exact head/base', async () => {
  const { calls, run } = harness();
  await run();
  assert.equal(calls.approvals.length, 1);
  assert.equal(calls.approvals[0].commit_id, head);
  assert.equal(calls.merges.length, 1);
  assert.equal(calls.statuses.find(s => s.context === 'CI validation').state, 'success');
});

test('code PR enables waiting merge but never gets robot approval', async () => {
  const { calls, run } = harness({ files: [{ filename: 'lib/search.dart', status: 'modified' }] });
  await run();
  assert.equal(calls.approvals.length, 0);
  assert.equal(calls.merges.length, 1);
  assert.equal(calls.statuses.find(s => s.context === 'PR policy').state, 'pending');
});

test('critical review without acceptance marker stays blocked even with green CI', async () => {
  const { calls, run } = harness({ files: [{ filename: 'lib/services/prefs_bridge.dart', status: 'modified' }],
    reviews: [{ state: 'APPROVED', commit_id: head, body: '', user: { login: 'reviewer', type: 'User' } }] });
  await run();
  assert.equal(calls.statuses.find(s => s.context === 'PR policy').state, 'pending');
  assert.equal(calls.approvals.length, 0);
});

test('missing run dispatches exact head/base and leaves docs without approval', async () => {
  const { calls, run } = harness({ hasRun: false });
  await run();
  assert.deepEqual(calls.dispatches[0].inputs, { pr_number: '1', head_sha: head, base_sha: base });
  assert.equal(calls.approvals.length, 0);
  assert.equal(calls.statuses.find(s => s.context === 'CI validation').state, 'pending');
});

test('nominally successful workflow with missing Windows build is rejected', async () => {
  const { calls, run } = harness({ jobs: ['automation-tests', 'analyze-test'] });
  await run();
  assert.equal(calls.statuses.find(s => s.context === 'CI validation').state, 'failure');
  assert.equal(calls.approvals.length, 0);
});

test('head changing during classification prevents all status, approval and merge mutations', async () => {
  const { calls, run } = harness({ changedHead: true });
  await run();
  assert.equal(calls.statuses.length + calls.approvals.length + calls.merges.length, 0);
});

test('incomplete file list fails closed', async () => {
  const { calls, run } = harness({ incompleteFiles: true });
  await run();
  assert.equal(calls.failed.length, 1);
  assert.equal(calls.statuses.at(-1).state, 'failure');
  assert.equal(calls.approvals.length + calls.merges.length + calls.dispatches.length, 0);
});

test('workflow changes still get validation but never request unsupported token-based auto-merge', async () => {
  const { calls, run } = harness({ files: [{ filename: '.github/workflows/release.yml', status: 'added' }], hasRun: false });
  await run();
  assert.equal(calls.merges.length, 0);
  assert.equal(calls.dispatches.length, 1);
  assert.equal(calls.failed.length, 0);
});

test('callback can reconcile once all validation jobs passed, while notification job finishes', async () => {
  const { calls, run } = harness({ runStatus: 'in_progress' });
  await run();
  assert.equal(calls.statuses.find(s => s.context === 'CI validation').state, 'success');
  assert.equal(calls.approvals.length, 1);
});

test('failed validation job publishes failure while notification job finishes', async () => {
  const { calls, run } = harness({ runStatus: 'in_progress', jobFailures: ['windows-build'] });
  await run();
  assert.equal(calls.statuses.find(s => s.context === 'CI validation').state, 'failure');
  assert.equal(calls.approvals.length, 0);
});
