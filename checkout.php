<?php
require_once __DIR__ . '/includes/config.php';
$page = 'checkout'; $title = 'Checkout';

$t = cart_totals();
if (!$t['lines']) redirect('cart.php');

$errors = [];

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    check_csrf();

    $c = [
        'name'    => post('name'),
        'email'   => post('email'),
        'phone'   => post('phone'),
        'address' => post('address'),
        'city'    => post('city'),
        'state'   => post('state'),
        'zip'     => post('zip'),
        'country' => post('country', 'United States'),
    ];
    if ($c['name'] === '')    $errors[] = 'Add your full name.';
    if (!filter_var($c['email'], FILTER_VALIDATE_EMAIL)) $errors[] = 'Add a valid email address.';
    if ($c['address'] === '') $errors[] = 'Add a street address.';
    if ($c['city'] === '')    $errors[] = 'Add a city.';
    if ($c['zip'] === '')     $errors[] = 'Add a postal code.';
    if (post('website') !== '') $errors[] = 'Something went wrong. Try again.';

    if (!$errors) {
        $order = [
            'id'       => uid('o_'),
            'ref'      => strtoupper('NG-' . date('ymd') . '-' . substr(bin2hex(random_bytes(2)), 0, 4)),
            'at'       => date('c'),
            'status'   => 'awaiting payment',
            'customer' => $c,
            'notes'    => post('notes'),
            'lines'    => $t['lines'],
            'totals'   => [
                'subtotal' => $t['subtotal'], 'assembly' => $t['assembly'],
                'shipping' => $t['shipping'], 'tax' => $t['tax'], 'grand' => $t['grand'],
            ],
            'payment'  => ['method' => stripe_enabled() ? 'Card / Apple Pay (Stripe)' : 'Invoice sent by us', 'reference' => ''],
        ];
        save_order($order);

        if (stripe_enabled()) {
            $base = (isset($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off' ? 'https' : 'http')
                  . '://' . $_SERVER['HTTP_HOST'] . rtrim(dirname($_SERVER['PHP_SELF']), '/\\');
            $url = stripe_checkout_url(
                $order,
                $base . '/order-complete.php?order=' . $order['id'] . '&paid=1',
                $base . '/checkout.php',
                $stripeErr
            );
            if ($url) { redirect($url); }
            $errors[] = 'Card payment is temporarily unavailable (' . $stripeErr . '). Your order was saved — we will email you an invoice.';
            update_order($order['id'], ['status' => 'invoice pending']);
        }

        notify_order(get_order($order['id']));
        cart_clear();
        redirect('order-complete.php?order=' . $order['id']);
    }
}

include __DIR__ . '/includes/header.php';
?>
<section class="section">
  <div class="shell">
    <h1>Checkout</h1>
    <div class="build-layout" style="margin-top:24px">
      <div class="panel">
        <?php foreach ($errors as $err): ?><div class="notice notice-bad"><?= e($err) ?></div><?php endforeach; ?>

        <form method="post" novalidate>
          <?= csrf_field() ?>
          <div style="position:absolute;left:-9999px" aria-hidden="true"><input type="text" name="website" tabindex="-1" autocomplete="off"></div>

          <h3>Where should this go?</h3>
          <div class="row2">
            <div class="field"><label for="f-name">Full name</label><input id="f-name" type="text" name="name" autocomplete="name" value="<?= e(post('name')) ?>" required></div>
            <div class="field"><label for="f-email">Email</label><input id="f-email" type="email" name="email" autocomplete="email" value="<?= e(post('email')) ?>" required></div>
          </div>
          <div class="field"><label for="f-phone">Phone (optional)</label><input id="f-phone" type="tel" name="phone" autocomplete="tel" value="<?= e(post('phone')) ?>"></div>
          <div class="field"><label for="f-addr">Street address</label><textarea id="f-addr" name="address" style="min-height:70px" autocomplete="street-address" required><?= e(post('address')) ?></textarea></div>
          <div class="row2">
            <div class="field"><label for="f-city">City</label><input id="f-city" type="text" name="city" autocomplete="address-level2" value="<?= e(post('city')) ?>" required></div>
            <div class="field"><label for="f-state">State / region</label><input id="f-state" type="text" name="state" autocomplete="address-level1" value="<?= e(post('state')) ?>"></div>
          </div>
          <div class="row2">
            <div class="field"><label for="f-zip">Postal code</label><input id="f-zip" type="text" name="zip" autocomplete="postal-code" value="<?= e(post('zip')) ?>" required></div>
            <div class="field"><label for="f-country">Country</label><input id="f-country" type="text" name="country" autocomplete="country-name" value="<?= e(post('country', 'United States')) ?>"></div>
          </div>
          <div class="field"><label for="f-notes">Anything we should know? (optional)</label><textarea id="f-notes" name="notes" style="min-height:80px"><?= e(post('notes')) ?></textarea></div>

          <h3 style="margin-top:28px">Payment</h3>
          <?php if (stripe_enabled()): ?>
            <div class="notice notice-info">You'll pay on Stripe's secure page — card, Apple Pay or Google Pay. We never see or store your card number.</div>
            <button class="btn" type="submit">Continue to payment — <?= money($t['grand']) ?></button>
          <?php else: ?>
            <div class="notice notice-info">Card payment isn't switched on yet. Place the order and we'll email you an invoice you can pay from.</div>
            <button class="btn" type="submit">Place order — <?= money($t['grand']) ?></button>
          <?php endif; ?>
        </form>
      </div>

      <aside>
        <div class="summary">
          <h3>Order summary</h3>
          <?php foreach ($t['lines'] as $l): ?>
            <div class="line"><span><?= e($l['name']) ?> &times;<?= (int)$l['qty'] ?></span><span><?= money($l['total']) ?></span></div>
          <?php endforeach; ?>
          <?php if ($t['assembly']): ?><div class="line"><span>Assembly by us</span><span><?= money($t['assembly']) ?></span></div><?php endif; ?>
          <?php if ($t['shipping']): ?><div class="line"><span>Shipping</span><span><?= money($t['shipping']) ?></span></div><?php endif; ?>
          <?php if ($t['tax']): ?><div class="line"><span>Tax</span><span><?= money($t['tax']) ?></span></div><?php endif; ?>
          <div class="grand"><span>Total</span><span><?= money($t['grand']) ?></span></div>
          <a class="mono" style="color:#9fabb8" href="cart.php">Change something</a>
        </div>
      </aside>
    </div>
  </div>
</section>
<?php include __DIR__ . '/includes/footer.php'; ?>
