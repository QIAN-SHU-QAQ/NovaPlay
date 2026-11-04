const { test } = require('node:test');
const assert = require('node:assert/strict');
const { classifyFiles, evaluateReview, validationName, parseValidationName } = require('./policy.cjs');

const sha = 'a'.repeat(40);
const file = (filename, status = 'modified') => ({ filename, status });
const review = (state = 'APPROVED', body = '', commit_id = sha, login = 'maintainer') => ({
  state, body, commit_id, user: { login },
});

test('only added or modified Markdown in the documentation allowlist is automatic', () => {
  assert.equal(classifyFiles([file('README.md'), file('docs/guide.md', 'added')]).kind, 'docs');
  for (const files of [[], [file('docs/guide.md', 'removed')], [file('docs/guide.md', 'renamed')],
    [file('docs/guide.md'), file('lib/main.dart')], [file('docs/image.svg')],
    [file('docs/AGENTS.md')], [file('docs/skills/SKILL.md')], [file('.github/README.md')]]) {
    assert.notEqual(classifyFiles(files).kind, 'docs');
  }
});

test('storage, downloads, dependencies, native code and automation need acceptance', () => {
  for (const path of ['lib/services/database_service.dart', 'lib/services/prefs_bridge.dart',
    'lib/services/download_service.dart', 'lib/services/m3u8/m3u8_parser.dart',
    'lib/providers/history_provider.dart', 'lib/core/utils/play_launcher.dart',
    '.github/workflows/ci.yml', 'scripts/package.ps1', 'windows/runner/main.cpp', 'pubspec.lock']) {
    assert.equal(classifyFiles([file(path)]).kind, 'critical', path);
  }
  assert.equal(classifyFiles([file('lib/features/search/search_screen.dart')]).kind, 'code');
});

test('documentation needs no approval but a maintainer request for changes blocks it', () => {
  assert.equal(evaluateReview({ kind: 'docs', head: sha, author: 'author', reviews: [] }).allowed, true);
  assert.equal(evaluateReview({ kind: 'docs', head: sha, author: 'author',
    reviews: [review('CHANGES_REQUESTED')], maintainers: ['maintainer'] }).allowed, false);
});

test('code requires approval of the exact current head by a different maintainer', () => {
  const args = { kind: 'code', head: sha, author: 'author', maintainers: ['maintainer'] };
  assert.equal(evaluateReview({ ...args, reviews: [] }).allowed, false);
  assert.equal(evaluateReview({ ...args, reviews: [review()] }).allowed, true);
  assert.equal(evaluateReview({ ...args, reviews: [review('APPROVED', '', 'b'.repeat(40))] }).allowed, false);
  assert.equal(evaluateReview({ ...args, reviews: [review('APPROVED', '', sha, 'stranger')] }).allowed, false);
  assert.equal(evaluateReview({ ...args, author: 'maintainer', reviews: [review()] }).allowed, false);
});

test('comments do not erase a decision; dismissed or newer changes-requested decisions do', () => {
  const args = { kind: 'code', head: sha, author: 'author', maintainers: ['maintainer'] };
  assert.equal(evaluateReview({ ...args, reviews: [review(), review('COMMENTED')] }).allowed, true);
  assert.equal(evaluateReview({ ...args, reviews: [review(), review('DISMISSED')] }).allowed, false);
  assert.equal(evaluateReview({ ...args, reviews: [review(), review('CHANGES_REQUESTED')] }).allowed, false);
});

test('critical changes require an explicit acceptance marker in the current approval', () => {
  const args = { kind: 'critical', head: sha, author: 'author', maintainers: ['maintainer'] };
  assert.equal(evaluateReview({ ...args, reviews: [review()] }).allowed, false);
  assert.equal(evaluateReview({ ...args, reviews: [review('APPROVED', `Acceptance-SHA: ${sha}`)] }).allowed, true);
  for (const body of [`Acceptance-SHA: ${'b'.repeat(40)}`, `> Acceptance-SHA: ${sha}`,
    `Acceptance-SHA: ${sha}extra`, 'Acceptance-SHA:']) {
    assert.equal(evaluateReview({ ...args, reviews: [review('APPROVED', body)] }).allowed, false);
  }
});

test('validation identity includes PR number, exact head and exact base', () => {
  const name = validationName(7, sha, 'b'.repeat(40));
  assert.deepEqual(parseValidationName(name), { number: 7, head: sha, base: 'b'.repeat(40) });
  assert.equal(parseValidationName('CI PR #7'), null);
  assert.equal(parseValidationName(`${name} extra`), null);
});
