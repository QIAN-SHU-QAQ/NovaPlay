const { classifyFiles, evaluateReview, validationName } = require('./policy.cjs');

// Runs exclusively from the default branch. Never loads PR code or artifacts.
module.exports = async ({ github, context, core }) => {
  const repo = context.repo;
  const repository = (await github.rest.repos.get(repo)).data;
  const base = (await github.rest.repos.getBranch({ ...repo, branch: repository.default_branch })).data.commit.sha;
  const pulls = await github.paginate(github.rest.pulls.list, { ...repo, state: 'open', base: repository.default_branch, per_page: 100 });
  const runs = await github.paginate(github.rest.actions.listWorkflowRuns, {
    ...repo, workflow_id: 'ci.yml', event: 'workflow_dispatch', per_page: 100,
  });
  const permissions = new Map();
  const requiredJobs = ['automation-tests', 'analyze-test', 'windows-build'];

  const status = (sha, name, state, description, url) => github.rest.repos.createCommitStatus({
    ...repo, sha, context: name, state, description: description.slice(0, 140),
    ...(url ? { target_url: url } : {}),
  });

  for (const item of pulls) {
    let head;
    try {
      const pr = (await github.rest.pulls.get({ ...repo, pull_number: item.number })).data;
      head = pr.head.sha;
      const prParams = { ...repo, pull_number: pr.number };
      const files = await github.paginate(github.rest.pulls.listFiles, { ...prParams, per_page: 100 });
      if (!files.length || files.length !== pr.changed_files) throw new Error('Incomplete file list; refusing to classify');
      const { kind } = classifyFiles(files);
      const changesWorkflow = files.some(file => [file.filename, file.previous_filename || '']
        .some(path => path.startsWith('.github/workflows/')));
      const reviews = await github.paginate(github.rest.pulls.listReviews, { ...prParams, per_page: 100 });
      const maintainers = [];
      for (const review of reviews) {
        const user = review.user;
        if (!user || user.type === 'Bot' || user.login === pr.user.login) continue;
        if (!permissions.has(user.login)) {
          try {
            const result = await github.rest.repos.getCollaboratorPermissionLevel({ ...repo, username: user.login });
            permissions.set(user.login, ['admin', 'maintain', 'write'].includes(result.data.permission));
          } catch (error) {
            if (error.status !== 404) throw error;
            permissions.set(user.login, false);
          }
        }
        if (permissions.get(user.login)) maintainers.push(user.login);
      }
      const decision = evaluateReview({ kind, head, author: pr.user.login, reviews, maintainers });
      const current = (await github.rest.pulls.get(prParams)).data;
      if (current.state !== 'open' || current.head.sha !== head) continue;
      await status(head, 'PR policy', decision.allowed && !pr.draft ? 'success' : 'pending',
        pr.draft ? 'Draft PR: waiting for ready for review' : `${kind}: ${decision.reason}`);

      // Enable while checks/review are pending, so native protection does the
      // final merge. Code PRs still cannot pass the maintainer/acceptance gates.
      if (repository.allow_auto_merge && !pr.draft && !current.auto_merge && !changesWorkflow) {
        await github.graphql(`mutation($id: ID!) {
          enablePullRequestAutoMerge(input: {pullRequestId: $id, mergeMethod: SQUASH}) {
            pullRequest { number }
          }
        }`, { id: current.node_id });
      }
      if (changesWorkflow) core.info(`#${pr.number}: workflow files require a maintainer to perform the final merge`);

      const name = validationName(pr.number, head, base);
      const run = runs.filter(run => run.display_title === name && run.head_branch === repository.default_branch)
        .sort((a, b) => b.id - a.id)[0];
      let validated = false;
      if (pr.draft) {
        await status(head, 'CI validation', 'pending', 'Draft PR: validation starts when ready');
      } else if (!run) {
        await status(head, 'CI validation', 'pending', 'Dispatching isolated validation of exact PR head and base');
        await github.rest.actions.createWorkflowDispatch({
          ...repo, workflow_id: 'ci.yml', ref: repository.default_branch,
          inputs: { pr_number: String(pr.number), head_sha: head, base_sha: base },
        });
      } else {
        const jobs = await github.paginate(github.rest.actions.listJobsForWorkflowRun, {
          ...repo, run_id: run.id, filter: 'latest', per_page: 100,
        });
        validated = requiredJobs.every(name =>
          jobs.some(job => job.name === name && job.conclusion === 'success'));
        if (run.status === 'completed' && run.conclusion !== 'success') validated = false;
        const state = validated ? 'success' : run.status === 'completed' ? 'failure' : 'pending';
        await status(head, 'CI validation', state,
          validated ? 'Exact PR head/base: policy tests, Flutter tests and Windows build passed'
            : state === 'failure' ? 'Validation failed or required jobs missing; inspect run'
              : 'Isolated tests and Windows build running', run.html_url);
      }

      if (!validated || !decision.allowed || pr.draft) {
        core.info(`#${pr.number}: ${kind}; ${decision.reason}; validation=${validated}`);
        continue;
      }
      // Native branch protection also requires an approval. Only docs get a bot approval.
      if (kind === 'docs' && !reviews.some(review => review.user?.login === 'github-actions[bot]' &&
        review.state === 'APPROVED' && review.commit_id === head)) {
        await github.rest.pulls.createReview({
          ...prParams, commit_id: head, event: 'APPROVE',
          body: 'Documentation allowlist and exact-head CI validation passed. Code changes require maintainer review.',
        });
      }
      core.info(`#${pr.number}: review and validation passed; GitHub enforces remaining protections`);
    } catch (error) {
      // A failed controller must never leave a green policy check behind.
      if (head) await status(head, 'PR policy', 'failure', `Automation error: ${error.message}`).catch(() => {});
      core.error(`#${item.number}: ${error.message}`);
      core.setFailed('At least one PR could not be reconciled');
    }
  }
};
