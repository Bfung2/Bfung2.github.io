<?php
require_once __DIR__ . '/includes/config.php';
$page = 'tech'; $title = 'Request a tech';
$errors = []; $sent = false;

$services = ['Diagnose a problem','Virus / malware cleanup','Hardware upgrade or install','Data recovery or transfer','Network or Wi-Fi setup','Custom build assembly','Something else'];
$places   = ['At my home','At my business','I\'ll drop it off','Remote / over the phone'];

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    check_csrf();
    $name = post('name'); $email = post('email'); $phone = post('phone');
    $issue = post('issue');
    if ($name === '')  $errors[] = 'Add your name.';
    if (!filter_var($email, FILTER_VALIDATE_EMAIL)) $errors[] = 'Add an email address so we can confirm.';
    if (mb_strlen($issue) < 10) $errors[] = 'Describe the problem in a sentence or two.';
    if (post('website') !== '') $errors[] = 'Something went wrong. Try again.';

    if (!$errors) {
        $ref = strtoupper('TECH-' . date('ymd') . '-' . substr(bin2hex(random_bytes(2)), 0, 4));
        $body  = "TECH REQUEST $ref\n" . str_repeat('=', 46) . "\n\n";
        $body .= "Name:        $name\nEmail:       $email\nPhone:       $phone\n\n";
        $body .= "Service:     " . post('service') . "\n";
        $body .= "Location:    " . post('place') . "\n";
        $body .= "Address:     " . post('address') . "\n";
        $body .= "Device:      " . post('device') . "\n";
        $body .= "Best time:   " . post('when') . "\n";
        $body .= "Urgency:     " . post('urgency') . "\n\n";
        $body .= "THE PROBLEM\n" . str_repeat('-', 46) . "\n$issue\n";

        send_email(setting('owner_email'), "Tech request $ref — $name", $body, $email);
        send_email($email, setting('site_name') . " — we got your request ($ref)",
            "Thanks $name,\n\nWe've received your request and will get back to you to arrange a time.\n\nYour reference is $ref.\n\n$body\n" . setting('site_name') . "\n" . setting('phone'), setting('owner_email'));
        log_message('tech', ['ref' => $ref, 'name' => $name, 'email' => $email, 'phone' => $phone, 'issue' => $issue, 'service' => post('service')]);
        $sent = true; $sentRef = $ref;
    }
}
include __DIR__ . '/includes/header.php';
?>
<section class="section">
  <div class="shell">
    <div class="section-head">
      <div>
        <h1 style="margin-bottom:.2em">Request a tech</h1>
        <p class="muted">Tell us what's wrong and we'll come to you, or you can drop the machine off.</p>
      </div>
    </div>

    <div class="build-layout">
      <div class="panel">
        <?php if ($sent): ?>
          <div class="notice notice-ok">Request sent. Your reference is <strong><?= e($sentRef) ?></strong> — we've emailed you a copy and we'll be in touch to book a time.</div>
          <a class="btn btn-sm btn-quiet" href="index.php">Back to the shop</a>
        <?php else: ?>
          <?php foreach ($errors as $err): ?><div class="notice notice-bad"><?= e($err) ?></div><?php endforeach; ?>
          <form method="post" novalidate>
            <?= csrf_field() ?>
            <div style="position:absolute;left:-9999px" aria-hidden="true"><input type="text" name="website" tabindex="-1" autocomplete="off"></div>

            <div class="row2">
              <div class="field"><label for="t-name">Your name</label><input id="t-name" type="text" name="name" value="<?= e(post('name')) ?>" required></div>
              <div class="field"><label for="t-email">Email</label><input id="t-email" type="email" name="email" value="<?= e(post('email')) ?>" required></div>
            </div>
            <div class="row2">
              <div class="field"><label for="t-phone">Phone</label><input id="t-phone" type="tel" name="phone" value="<?= e(post('phone')) ?>"></div>
              <div class="field"><label for="t-service">What do you need?</label>
                <select id="t-service" name="service">
                  <?php foreach ($services as $svc): ?><option <?= post("service")===$svc?'selected':'' ?>><?= e($svc) ?></option><?php endforeach; ?>
                </select>
              </div>
            </div>
            <div class="row2">
              <div class="field"><label for="t-place">Where?</label>
                <select id="t-place" name="place">
                  <?php foreach ($places as $p): ?><option <?= post('place')===$p?'selected':'' ?>><?= e($p) ?></option><?php endforeach; ?>
                </select>
              </div>
              <div class="field"><label for="t-urgency">How soon?</label>
                <select id="t-urgency" name="urgency">
                  <option>Whenever you have space</option>
                  <option>Within a week</option>
                  <option>Within 48 hours</option>
                  <option>Today if possible</option>
                </select>
              </div>
            </div>
            <div class="field"><label for="t-address">Address (if we're coming to you)</label><input id="t-address" type="text" name="address" value="<?= e(post('address')) ?>"></div>
            <div class="row2">
              <div class="field"><label for="t-device">Machine</label><input id="t-device" type="text" name="device" placeholder="e.g. Dell XPS 15, or a desktop I built" value="<?= e(post('device')) ?>"></div>
              <div class="field"><label for="t-when">Best time to reach you</label><input id="t-when" type="text" name="when" placeholder="e.g. weekday evenings" value="<?= e(post('when')) ?>"></div>
            </div>
            <div class="field"><label for="t-issue">What's happening?</label><textarea id="t-issue" name="issue" placeholder="When it started, what you've already tried, any error messages" required><?= e(post('issue')) ?></textarea></div>
            <button class="btn" type="submit">Send request</button>
          </form>
        <?php endif; ?>
      </div>

      <aside>
        <div class="summary">
          <h3>What happens next</h3>
          <div class="line"><span>1. You send this form</span><span>now</span></div>
          <div class="line"><span>2. We email you back</span><span>same day</span></div>
          <div class="line"><span>3. We agree a time and price</span><span>before any work</span></div>
          <p style="color:#b9c3cd;font-size:.88rem;margin-top:16px">No diagnosis fee if you go ahead with the repair. If it's a parts problem, we'll quote from stock.</p>
          <?php if (setting('phone')): ?><p style="color:#fff;font-family:var(--mono)"><?= e(setting('phone')) ?></p><?php endif; ?>
        </div>
      </aside>
    </div>
  </div>
</section>
<?php include __DIR__ . '/includes/footer.php'; ?>
