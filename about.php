<?php
require_once __DIR__ . '/includes/config.php';
$page = 'about'; $title = 'About';
include __DIR__ . '/includes/header.php';
$heading = setting('about_heading', '');
$body    = setting('about_body', '');
?>
<section class="section">
  <div class="shell">
    <?php if ($heading === '' && $body === ''): ?>
      <div class="empty-state">
        <p>This page hasn't been written yet.</p>
        <?php if (is_admin()): ?><a class="btn btn-sm" href="admin/settings.php#about">Write the About page</a><?php endif; ?>
      </div>
    <?php else: ?>
      <h1><?= e($heading ?: 'About us') ?></h1>
      <div class="stack"><?php foreach (preg_split("/\n\s*\n/", $body) as $para) { if (trim($para) !== '') echo '<p>' . nl2br(e(trim($para))) . '</p>'; } ?></div>
      <?php if (is_admin()): ?><p><a class="btn btn-sm btn-quiet" href="admin/settings.php#about">Edit this page</a></p><?php endif; ?>
    <?php endif; ?>
  </div>
</section>
<?php include __DIR__ . '/includes/footer.php'; ?>
