<?php
require_once __DIR__ . '/includes/config.php';
$page = 'contact'; $title = 'Contact';
$errors = []; $sent = false;

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    check_csrf();
    $name = post('name'); $email = post('email'); $msg = post('message');
    if ($name === '')  $errors[] = 'Add your name.';
    if (!filter_var($email, FILTER_VALIDATE_EMAIL)) $errors[] = 'Add an email address we can reply to.';
    if (mb_strlen($msg) < 5) $errors[] = 'Tell us a bit more in the message.';
    if (post('website') !== '') $errors[] = 'Something went wrong. Try again.'; // honeypot

    if (!$errors) {
        $body = "New message from the contact form\n\n"
              . "Name:    $name\n"
              . "Email:   $email\n"
              . "Phone:   " . post('phone') . "\n"
              . "Sent:    " . date('D j M Y, g:ia') . "\n\n"
              . "----------------------------------------\n$msg\n";
        send_email(setting('owner_email'), 'Contact form: ' . $name, $body, $email);
        log_message('contact', compact('name','email','msg') + ['phone' => post('phone')]);
        $sent = true;
    }
}
include __DIR__ . '/includes/header.php';
?>
<section class="section">
  <div class="shell">
    <h1>Contact</h1>

    <?php if (setting('contact_body')): ?>
      <p><?= nl2br(e(setting('contact_body'))) ?></p>
    <?php elseif (is_admin()): ?>
      <div class="notice notice-info">No intro text on this page yet. <a href="admin/settings.php#contact">Add some</a>.</div>
    <?php endif; ?>

    <div class="build-layout" style="margin-top:28px">
      <div class="panel">
        <?php if ($sent): ?>
          <div class="notice notice-ok">Message sent. We'll reply to you by email.</div>
        <?php else: ?>
          <?php foreach ($errors as $err): ?><div class="notice notice-bad"><?= e($err) ?></div><?php endforeach; ?>
          <form method="post" novalidate>
            <?= csrf_field() ?>
            <div style="position:absolute;left:-9999px" aria-hidden="true"><input type="text" name="website" tabindex="-1" autocomplete="off"></div>
            <div class="row2">
              <div class="field"><label for="c-name">Your name</label><input id="c-name" type="text" name="name" value="<?= e(post('name')) ?>" required></div>
              <div class="field"><label for="c-email">Email</label><input id="c-email" type="email" name="email" value="<?= e(post('email')) ?>" required></div>
            </div>
            <div class="field"><label for="c-phone">Phone (optional)</label><input id="c-phone" type="tel" name="phone" value="<?= e(post('phone')) ?>"></div>
            <div class="field"><label for="c-msg">Message</label><textarea id="c-msg" name="message" required><?= e(post('message')) ?></textarea></div>
            <button class="btn" type="submit">Send message</button>
          </form>
        <?php endif; ?>
      </div>
      <div>
        <div class="summary">
          <h3>Reach us directly</h3>
          <?php if (setting('phone')):   ?><div class="line"><span>Phone</span><span><?= e(setting('phone')) ?></span></div><?php endif; ?>
          <?php if (setting('owner_email')): ?><div class="line"><span>Email</span><span><?= e(setting('owner_email')) ?></span></div><?php endif; ?>
          <?php if (setting('hours')):   ?><div class="line"><span>Hours</span><span><?= e(setting('hours')) ?></span></div><?php endif; ?>
          <?php if (setting('address')): ?><div class="line"><span>Address</span><span><?= e(setting('address')) ?></span></div><?php endif; ?>
          <p style="color:#b9c3cd;font-size:.86rem;margin-top:16px">Need someone to look at a machine in person? <a href="request-tech.php" style="color:var(--amber)">Request a tech</a>.</p>
        </div>
      </div>
    </div>
  </div>
</section>
<?php include __DIR__ . '/includes/footer.php'; ?>
