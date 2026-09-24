<?php
$title = 'Settings';
require_once __DIR__ . '/../includes/admin-header.php';

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    check_csrf();

    if (post('action') === 'password') {
        $cur = $_POST['current'] ?? ''; $new = $_POST['new'] ?? ''; $again = $_POST['again'] ?? '';
        $hash = setting('admin_hash', '');
        $ok = $hash ? password_verify($cur, $hash) : hash_equals(ADMIN_DEFAULT_PASSWORD, $cur);
        if (!$ok)                      flash('Your current password was wrong.');
        elseif (strlen($new) < 10)     flash('Use at least 10 characters for the new password.');
        elseif ($new !== $again)       flash('The two new passwords did not match.');
        else { save_settings(['admin_hash' => password_hash($new, PASSWORD_DEFAULT)]); flash('Password changed.'); }
        redirect('settings.php#password');
    }

    save_settings([
        'site_name'       => post('site_name'),
        'tagline'         => post('tagline'),
        'owner_email'     => post('owner_email'),
        'from_email'      => post('from_email'),
        'phone'           => post('phone'),
        'address'         => post('address'),
        'hours'           => post('hours'),
        'currency'        => post('currency', '$'),
        'build_fee'       => (float)post('build_fee'),
        'offer_assembly'  => post('offer_assembly') === '1' ? 1 : 0,
        'tax_rate'        => (float)post('tax_rate'),
        'shipping_flat'   => (float)post('shipping_flat'),
        'about_heading'   => post('about_heading'),
        'about_body'      => post('about_body'),
        'contact_body'    => post('contact_body'),
        'payment_mode'    => post('payment_mode') === 'stripe' ? 'stripe' : 'invoice',
        'stripe_pk'       => post('stripe_pk'),
        'stripe_sk'       => post('stripe_sk'),
        'stripe_currency' => strtolower(post('stripe_currency', 'usd')),
    ]);
    flash('Settings saved.');
    redirect('settings.php');
}
$s = settings();
?>
<h1>Settings</h1>
<p class="muted">Everything on this page changes the live site straight away. No code editing.</p>

<form method="post">
  <?= csrf_field() ?>

  <div class="panel" style="margin-bottom:22px">
    <h2 style="font-size:1.2rem">The basics</h2>
    <div class="row2">
      <div class="field"><label for="site_name">Business name</label><input id="site_name" type="text" name="site_name" value="<?= e($s['site_name']) ?>"></div>
      <div class="field"><label for="tagline">One-line description</label><input id="tagline" type="text" name="tagline" value="<?= e($s['tagline']) ?>"></div>
    </div>
    <div class="row2">
      <div class="field"><label for="phone">Phone</label><input id="phone" type="tel" name="phone" value="<?= e($s['phone']) ?>"></div>
      <div class="field"><label for="hours">Opening hours</label><input id="hours" type="text" name="hours" value="<?= e($s['hours']) ?>" placeholder="Mon–Sat, 9–6"></div>
    </div>
    <div class="field"><label for="address">Address</label><input id="address" type="text" name="address" value="<?= e($s['address']) ?>"></div>
  </div>

  <div class="panel" style="margin-bottom:22px" id="email">
    <h2 style="font-size:1.2rem">Where orders and messages go</h2>
    <div class="row2">
      <div class="field">
        <label for="owner_email">Your email address</label>
        <input id="owner_email" type="email" name="owner_email" value="<?= e($s['owner_email']) ?>" placeholder="you@yourshop.com">
        <div class="hint">Every order, contact message and tech request lands here, with the parts list, the customer's address and their email.</div>
      </div>
      <div class="field">
        <label for="from_email">Send mail from</label>
        <input id="from_email" type="email" name="from_email" value="<?= e($s['from_email']) ?>" placeholder="orders@yourshop.com">
        <div class="hint">Use an address on your own domain or the mail will land in spam.</div>
      </div>
    </div>
  </div>

  <div class="panel" style="margin-bottom:22px">
    <h2 style="font-size:1.2rem">Pricing</h2>
    <label class="checkrow" style="margin-bottom:16px">
      <input type="checkbox" name="offer_assembly" value="1" <?= $s['offer_assembly'] ? 'checked' : '' ?>>
      <span><strong>Offer to assemble builds</strong><br><span class="muted" style="font-size:.86rem">Untick this and customers can only buy parts loose — the build option disappears from the site.</span></span>
    </label>
    <div class="row2">
      <div class="field"><label for="build_fee">Assembly fee</label><input id="build_fee" type="number" step="0.01" min="0" name="build_fee" value="<?= e($s['build_fee']) ?>"><div class="hint">Added once per order when the customer ticks the build option.</div></div>
      <div class="field"><label for="currency">Currency symbol</label><input id="currency" type="text" name="currency" value="<?= e($s['currency']) ?>" maxlength="3"></div>
    </div>
    <div class="row2">
      <div class="field"><label for="tax_rate">Tax rate (%)</label><input id="tax_rate" type="number" step="0.01" min="0" name="tax_rate" value="<?= e($s['tax_rate']) ?>"><div class="hint">Leave at 0 if you handle tax elsewhere.</div></div>
      <div class="field"><label for="shipping_flat">Flat shipping</label><input id="shipping_flat" type="number" step="0.01" min="0" name="shipping_flat" value="<?= e($s['shipping_flat']) ?>"></div>
    </div>
  </div>

  <div class="panel" style="margin-bottom:22px" id="payments">
    <h2 style="font-size:1.2rem">Taking payment</h2>
    <div class="notice notice-info">
      Money reaches your bank through Stripe, not through this website. You connect your bank account once in your Stripe dashboard and Stripe deposits takings on a schedule. This site never sees or stores a card number — customers type it on Stripe's own page, which is what keeps you out of PCI compliance obligations. Apple Pay and Google Pay come along with it automatically.
    </div>
    <div class="field">
      <label for="payment_mode">Payment method</label>
      <select id="payment_mode" name="payment_mode">
        <option value="invoice" <?= $s['payment_mode']==='invoice'?'selected':'' ?>>Invoice — take the order, bill them yourself</option>
        <option value="stripe"  <?= $s['payment_mode']==='stripe'?'selected':'' ?>>Stripe — card, Apple Pay and Google Pay at checkout</option>
      </select>
    </div>
    <div class="row2">
      <div class="field"><label for="stripe_pk">Stripe publishable key</label><input id="stripe_pk" type="text" name="stripe_pk" value="<?= e($s['stripe_pk']) ?>" placeholder="pk_live_…"></div>
      <div class="field"><label for="stripe_sk">Stripe secret key</label><input id="stripe_sk" type="text" name="stripe_sk" value="<?= e($s['stripe_sk']) ?>" placeholder="sk_live_…"><div class="hint">Keep this one private. Anyone with it can move money on your account.</div></div>
    </div>
    <div class="field" style="max-width:220px"><label for="stripe_currency">Stripe currency</label><input id="stripe_currency" type="text" name="stripe_currency" value="<?= e($s['stripe_currency']) ?>" maxlength="3" placeholder="usd"></div>
  </div>

  <div class="panel" style="margin-bottom:22px" id="about">
    <h2 style="font-size:1.2rem">About page</h2>
    <div class="field"><label for="about_heading">Heading</label><input id="about_heading" type="text" name="about_heading" value="<?= e($s['about_heading']) ?>"></div>
    <div class="field"><label for="about_body">Body text</label><textarea id="about_body" name="about_body" style="min-height:200px"><?= e($s['about_body']) ?></textarea><div class="hint">Leave a blank line between paragraphs.</div></div>
  </div>

  <div class="panel" style="margin-bottom:22px" id="contact">
    <h2 style="font-size:1.2rem">Contact page</h2>
    <div class="field"><label for="contact_body">Intro text above the form</label><textarea id="contact_body" name="contact_body"><?= e($s['contact_body']) ?></textarea></div>
  </div>

  <button class="btn" type="submit">Save all settings</button>
</form>

<div class="panel" style="margin-top:32px" id="password">
  <h2 style="font-size:1.2rem">Change your password</h2>
  <?php if (setting('admin_hash') === ''): ?>
    <div class="notice notice-bad">You're still on the default password from <code>includes/config.php</code>. Change it now.</div>
  <?php endif; ?>
  <form method="post">
    <?= csrf_field() ?>
    <input type="hidden" name="action" value="password">
    <div class="field" style="max-width:360px"><label for="current">Current password</label><input id="current" type="password" name="current" autocomplete="current-password" required></div>
    <div class="row2" style="max-width:740px">
      <div class="field"><label for="new">New password</label><input id="new" type="password" name="new" autocomplete="new-password" required></div>
      <div class="field"><label for="again">New password again</label><input id="again" type="password" name="again" autocomplete="new-password" required></div>
    </div>
    <button class="btn btn-dark" type="submit">Change password</button>
  </form>
  <p class="hint" style="margin-top:12px">Your username stays <strong><?= e(ADMIN_USERNAME) ?></strong>. To change it, edit <code>includes/config.php</code>.</p>
</div>

<?php require_once __DIR__ . '/../includes/admin-footer.php'; ?>
