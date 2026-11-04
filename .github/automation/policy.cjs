function classifyFiles(files) {
  const documentation = ({ filename, status }) =>
    ['added', 'modified'].includes(status) &&
    (filename === 'README.md' || /^docs\/.+\.md$/.test(filename)) &&
    !/(^|\/)(AGENTS|CLAUDE|SKILL)\.md$/i.test(filename);
  if (files.length > 0 && files.every(documentation)) return { kind: 'docs' };
  const critical = /^(\.github\/|scripts\/|windows\/|pubspec\.(yaml|lock)$|lib\/(main\.dart$|services\/(database_service|prefs_bridge|download_service)\.dart$|services\/m3u8\/|models\/history_item\.dart$|providers\/history_provider\.dart$|features\/history\/|core\/utils\/play_launcher\.dart$))/;
  return { kind: files.some(file => critical.test(file.filename) || critical.test(file.previous_filename || '')) ? 'critical' : 'code' };
}

function evaluateReview({ kind, head, author, reviews, maintainers = [] }) {
  const decisions = new Map();
  for (const review of reviews) {
    if (!maintainers.includes(review.user?.login) || review.user.login === author) continue;
    if (['APPROVED', 'CHANGES_REQUESTED', 'DISMISSED'].includes(review.state)) {
      decisions.set(review.user.login, review);
    }
  }
  if ([...decisions.values()].some(review => review.state === 'CHANGES_REQUESTED')) {
    return { allowed: false, reason: 'Maintainer requested changes' };
  }
  if (kind === 'docs') return { allowed: true, reason: 'Documentation allowlist' };
  const approvals = [...decisions.values()].filter(review => review.state === 'APPROVED' && review.commit_id === head);
  if (approvals.length === 0) return { allowed: false, reason: 'Current head needs maintainer approval' };
  if (kind === 'critical' && !approvals.some(review =>
    (review.body || '').split(/\r?\n/).some(line => line === `Acceptance-SHA: ${head}`))) {
    return { allowed: false, reason: 'Current approval needs Acceptance-SHA evidence' };
  }
  return { allowed: true, reason: 'Current head approved' };
}

function validationName(number, head, base) {
  return `CI PR #${number} head:${head} base:${base}`;
}

function parseValidationName(name) {
  const match = /^CI PR #([1-9]\d*) head:([a-f0-9]{40}) base:([a-f0-9]{40})$/.exec(name);
  return match ? { number: Number(match[1]), head: match[2], base: match[3] } : null;
}

module.exports = { classifyFiles, evaluateReview, validationName, parseValidationName };
