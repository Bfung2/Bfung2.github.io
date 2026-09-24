<?php
$title = 'Messages';
require_once __DIR__ . '/../includes/admin-header.php';

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    check_csrf();
    if (post('action') === 'clear') { write_json('messages', []); flash('Message log cleared.'); }
    redirect('messages.php');
}
$msgs = read_json('messages');
?>
<h1>Messages</h1>
<p class="muted">Everything sent through the contact form and the tech request page. These are also emailed to you — this is the backup copy in case email fails.</p>

<?php if (!$msgs): ?>
  <div class="empty-state"><p>Nothing here yet.</p></div>
<?php else: ?>
  <?php foreach ($msgs as $m): $d = $m['data']; ?>
    <div class="panel" style="margin-bottom:14px">
      <div style="display:flex;justify-content:space-between;gap:14px;flex-wrap:wrap">
        <strong><?= e($d['name'] ?? 'Unknown') ?>
          <span class="tag"><?= $m['type'] === 'tech' ? 'tech request' : 'contact form' ?></span>
          <?php if (!empty($d['ref'])): ?><span class="mono muted"><?= e($d['ref']) ?></span><?php endif; ?>
        </strong>
        <span class="mono muted" style="font-size:.78rem"><?= e(date('j M Y, g:ia', strtotime($m['at']))) ?></span>
      </div>
      <p class="mono" style="font-size:.82rem;margin:6px 0">
        <a href="mailto:<?= e($d['email'] ?? '') ?>"><?= e($d['email'] ?? '') ?></a>
        <?= !empty($d['phone']) ? ' · ' . e($d['phone']) : '' ?>
        <?= !empty($d['service']) ? ' · ' . e($d['service']) : '' ?>
      </p>
      <p style="margin:0"><?= nl2br(e($d['issue'] ?? $d['msg'] ?? '')) ?></p>
    </div>
  <?php endforeach; ?>
  <form method="post" onsubmit="return confirm('Clear the whole message log?')">
    <?= csrf_field() ?>
    <input type="hidden" name="action" value="clear">
    <button class="btn btn-sm btn-danger" type="submit">Clear log</button>
  </form>
<?php endif; ?>
<?php require_once __DIR__ . '/../includes/admin-footer.php'; ?>
