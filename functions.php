<?php
/* ------------------------------------------------------------------ */
/* JSON storage — no database to install. Files live in /data          */
/* ------------------------------------------------------------------ */

function data_file($name) { return DATA_DIR . '/' . $name . '.json'; }

function read_json($name, $fallback = []) {
    $f = data_file($name);
    if (!file_exists($f)) return $fallback;
    $raw = file_get_contents($f);
    $out = json_decode($raw, true);
    return is_array($out) ? $out : $fallback;
}

function write_json($name, $data) {
    if (!is_dir(DATA_DIR)) @mkdir(DATA_DIR, 0775, true);
    $f   = data_file($name);
    $tmp = $f . '.tmp';
    file_put_contents($tmp, json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES), LOCK_EX);
    return rename($tmp, $f);
}

/* ------------------------------------------------------------------ */
/* Settings                                                            */
/* ------------------------------------------------------------------ */

function default_settings() {
    return [
        'site_name'      => 'Northgate PC Works',
        'tagline'        => 'Parts, custom builds and on-site repair.',
        'owner_email'    => '',
        'from_email'     => '',
        'phone'          => '',
        'address'        => '',
        'hours'          => '',
        'build_fee'      => 250,
        'offer_assembly' => 1,
        'tax_rate'       => 0,
        'shipping_flat'  => 0,
        'currency'       => '$',
        'about_heading'  => '',
        'about_body'     => '',
        'contact_body'   => '',
        'payment_mode'   => 'invoice',
        'stripe_pk'       => '',
        'stripe_sk'       => '',
        'stripe_currency' => 'usd',
        'payout_note'    => '',
        'admin_hash'     => '',
    ];
}

function settings() {
    static $s = null;
    if ($s === null) $s = array_merge(default_settings(), read_json('settings'));
    return $s;
}

function setting($key, $default = '') {
    $s = settings();
    return isset($s[$key]) && $s[$key] !== '' ? $s[$key] : $default;
}

function save_settings($new) {
    $s = array_merge(settings(), $new);
    write_json('settings', $s);
    return $s;
}

/* ------------------------------------------------------------------ */
/* Auth                                                                */
/* ------------------------------------------------------------------ */

function is_admin() { return !empty($_SESSION['is_admin']); }

function require_admin() {
    if (!is_admin()) { header('Location: login.php'); exit; }
}

function attempt_login($user, $pass) {
    if ($user !== ADMIN_USERNAME) return false;
    $hash = setting('admin_hash', '');

    if ($hash === '') {
        // First ever login — accept the password from config.php, then hash it.
        if (hash_equals(ADMIN_DEFAULT_PASSWORD, $pass)) {
            save_settings(['admin_hash' => password_hash($pass, PASSWORD_DEFAULT)]);
            $_SESSION['is_admin'] = true;
            session_regenerate_id(true);
            return true;
        }
        return false;
    }

    if (password_verify($pass, $hash)) {
        $_SESSION['is_admin'] = true;
        session_regenerate_id(true);
        return true;
    }
    return false;
}

/* ------------------------------------------------------------------ */
/* Helpers                                                             */
/* ------------------------------------------------------------------ */

function e($v) { return htmlspecialchars((string)$v, ENT_QUOTES, 'UTF-8'); }

function money($n) { return setting('currency', '$') . number_format((float)$n, 2); }

function uid($prefix = '') { return $prefix . bin2hex(random_bytes(6)); }

function csrf_token() {
    if (empty($_SESSION['csrf'])) $_SESSION['csrf'] = bin2hex(random_bytes(16));
    return $_SESSION['csrf'];
}

function csrf_field() {
    return '<input type="hidden" name="csrf" value="' . e(csrf_token()) . '">';
}

function check_csrf() {
    $t = $_POST['csrf'] ?? '';
    if (!$t || empty($_SESSION['csrf']) || !hash_equals($_SESSION['csrf'], $t)) {
        http_response_code(400);
        exit('Your session expired. Go back, reload the page and try again.');
    }
}

function flash($msg = null) {
    if ($msg !== null) { $_SESSION['flash'] = $msg; return; }
    $m = $_SESSION['flash'] ?? null;
    unset($_SESSION['flash']);
    return $m;
}

function redirect($url) { header('Location: ' . $url); exit; }

function post($key, $default = '') { return isset($_POST[$key]) ? trim((string)$_POST[$key]) : $default; }

/* ------------------------------------------------------------------ */
/* Catalogue                                                           */
/* ------------------------------------------------------------------ */

function all_products() { return read_json('products'); }
function all_parts()    { return read_json('parts'); }

function find_by_id($list, $id) {
    foreach ($list as $row) if (($row['id'] ?? '') === $id) return $row;
    return null;
}

function part_categories() {
    return [
        'cpu'         => 'Processor',
        'motherboard' => 'Motherboard',
        'ram'         => 'Memory',
        'gpu'         => 'Graphics card',
        'storage'     => 'Storage',
        'psu'         => 'Power supply',
        'case'        => 'Case',
        'cooler'      => 'CPU cooler',
        'other'       => 'Other',
    ];
}

/* ------------------------------------------------------------------ */
/* Image upload                                                        */
/* ------------------------------------------------------------------ */

function handle_upload($field, $existing = '') {
    if (empty($_FILES[$field]['name']) || $_FILES[$field]['error'] !== UPLOAD_ERR_OK) return $existing;
    $allowed = ['image/jpeg' => 'jpg', 'image/png' => 'png', 'image/webp' => 'webp', 'image/gif' => 'gif'];
    $info = @getimagesize($_FILES[$field]['tmp_name']);
    if (!$info || !isset($allowed[$info['mime']])) return $existing;
    if ($_FILES[$field]['size'] > 6 * 1024 * 1024) return $existing;
    if (!is_dir(UPLOAD_DIR)) @mkdir(UPLOAD_DIR, 0775, true);
    $name = uid('img_') . '.' . $allowed[$info['mime']];
    if (move_uploaded_file($_FILES[$field]['tmp_name'], UPLOAD_DIR . '/' . $name)) return $name;
    return $existing;
}

function img_url($file) {
    return $file ? UPLOAD_URL . '/' . rawurlencode($file) : '';
}

/* ------------------------------------------------------------------ */
/* Cart (session based)                                                */
/* ------------------------------------------------------------------ */

function cart() { return $_SESSION['cart'] ?? []; }

function cart_add($type, $id, $qty = 1) {
    $c = cart();
    $key = $type . ':' . $id;
    $c[$key] = ['type' => $type, 'id' => $id, 'qty' => max(1, (int)($c[$key]['qty'] ?? 0) + $qty)];
    $_SESSION['cart'] = $c;
}

function cart_set_qty($key, $qty) {
    $c = cart();
    $qty = (int)$qty;
    if ($qty <= 0) unset($c[$key]); elseif (isset($c[$key])) $c[$key]['qty'] = $qty;
    $_SESSION['cart'] = $c;
}

function cart_clear() { unset($_SESSION['cart'], $_SESSION['assembly']); }

function cart_count() {
    $n = 0;
    foreach (cart() as $l) $n += $l['qty'];
    return $n;
}

/** Expands the cart into full rows with names and prices. */
function cart_lines() {
    $products = all_products();
    $parts    = all_parts();
    $out = [];
    foreach (cart() as $key => $l) {
        $row = $l['type'] === 'part' ? find_by_id($parts, $l['id']) : find_by_id($products, $l['id']);
        if (!$row) continue;
        $out[] = [
            'key'   => $key,
            'type'  => $l['type'],
            'id'    => $l['id'],
            'name'  => $row['name'],
            'price' => (float)$row['price'],
            'image' => $row['image'] ?? '',
            'qty'   => (int)$l['qty'],
            'total' => (float)$row['price'] * (int)$l['qty'],
        ];
    }
    return $out;
}

function cart_totals() {
    $lines = cart_lines();
    $sub = 0;
    foreach ($lines as $l) $sub += $l['total'];

    $assembly = !empty($_SESSION['assembly']) ? (float)setting('build_fee', 250) : 0;
    $ship     = $sub > 0 ? (float)setting('shipping_flat', 0) : 0;
    $taxable  = $sub + $assembly + $ship;
    $tax      = $taxable * ((float)setting('tax_rate', 0) / 100);

    return [
        'lines'    => $lines,
        'subtotal' => $sub,
        'assembly' => $assembly,
        'shipping' => $ship,
        'tax'      => $tax,
        'grand'    => $taxable + $tax,
    ];
}

/* ------------------------------------------------------------------ */
/* Email                                                               */
/* ------------------------------------------------------------------ */

function send_email($to, $subject, $body, $reply_to = '') {
    if (!$to || !filter_var($to, FILTER_VALIDATE_EMAIL)) return false;
    $from = setting('from_email', '') ?: ('no-reply@' . ($_SERVER['HTTP_HOST'] ?? 'localhost'));
    $headers = [
        'From: ' . setting('site_name', 'Website') . ' <' . $from . '>',
        'Content-Type: text/plain; charset=UTF-8',
        'MIME-Version: 1.0',
    ];
    if ($reply_to && filter_var($reply_to, FILTER_VALIDATE_EMAIL)) $headers[] = 'Reply-To: ' . $reply_to;
    return @mail($to, $subject, $body, implode("\r\n", $headers));
}

function log_message($type, $payload) {
    $log = read_json('messages');
    array_unshift($log, ['id' => uid('m_'), 'type' => $type, 'at' => date('c'), 'data' => $payload]);
    write_json('messages', array_slice($log, 0, 500));
}

/* ------------------------------------------------------------------ */
/* Orders                                                              */
/* ------------------------------------------------------------------ */

function save_order($order) {
    $orders = read_json('orders');
    array_unshift($orders, $order);
    write_json('orders', $orders);
}

function update_order($id, $changes) {
    $orders = read_json('orders');
    foreach ($orders as $i => $o) {
        if ($o['id'] === $id) { $orders[$i] = array_merge($o, $changes); write_json('orders', $orders); return $orders[$i]; }
    }
    return null;
}

function get_order($id) { return find_by_id(read_json('orders'), $id); }

function order_email_body($o) {
    $b  = "ORDER " . $o['ref'] . "\n";
    $b .= "Placed: " . date('D j M Y, g:ia', strtotime($o['at'])) . "\n";
    $b .= "Status: " . strtoupper($o['status']) . "\n";
    $b .= str_repeat('=', 52) . "\n\n";

    $b .= "CUSTOMER\n";
    $b .= "  Name:    {$o['customer']['name']}\n";
    $b .= "  Email:   {$o['customer']['email']}\n";
    $b .= "  Phone:   {$o['customer']['phone']}\n\n";

    $b .= "SHIPPING ADDRESS\n";
    foreach (explode("\n", $o['customer']['address']) as $line) $b .= "  " . trim($line) . "\n";
    $b .= "  {$o['customer']['city']}, {$o['customer']['state']} {$o['customer']['zip']}\n";
    $b .= "  {$o['customer']['country']}\n\n";

    $b .= "PARTS LIST\n";
    $b .= str_repeat('-', 52) . "\n";
    foreach ($o['lines'] as $l) {
        $b .= sprintf("  %-32s x%-3d %10s\n", mb_substr($l['name'], 0, 32), $l['qty'], money($l['total']));
    }
    $b .= str_repeat('-', 52) . "\n";
    $b .= sprintf("  %-36s %10s\n", 'Subtotal', money($o['totals']['subtotal']));
    if ($o['totals']['assembly']) $b .= sprintf("  %-36s %10s\n", 'Assembly by us', money($o['totals']['assembly']));
    if ($o['totals']['shipping']) $b .= sprintf("  %-36s %10s\n", 'Shipping', money($o['totals']['shipping']));
    if ($o['totals']['tax'])      $b .= sprintf("  %-36s %10s\n", 'Tax', money($o['totals']['tax']));
    $b .= sprintf("  %-36s %10s\n", 'TOTAL', money($o['totals']['grand']));
    $b .= "\n";

    $b .= $o['totals']['assembly']
        ? "ASSEMBLY: yes — customer paid the build fee. Build and test before shipping.\n"
        : "ASSEMBLY: no — ship the parts loose, unassembled.\n";

    if (!empty($o['notes'])) $b .= "\nCUSTOMER NOTES\n  " . str_replace("\n", "\n  ", $o['notes']) . "\n";
    $b .= "\nPayment method: " . $o['payment']['method'] . "\n";
    if (!empty($o['payment']['reference'])) $b .= "Payment reference: " . $o['payment']['reference'] . "\n";
    return $b;
}

function notify_order($o) {
    $owner = setting('owner_email');
    send_email($owner, 'New order ' . $o['ref'] . ' — ' . money($o['totals']['grand']), order_email_body($o), $o['customer']['email']);

    $cust  = "Thanks " . $o['customer']['name'] . ",\n\nWe've got your order " . $o['ref'] . ".\n\n";
    $cust .= order_email_body($o);
    $cust .= "\nWe'll be in touch at this address with tracking.\n\n" . setting('site_name') . "\n";
    if (setting('phone')) $cust .= setting('phone') . "\n";
    send_email($o['customer']['email'], setting('site_name') . ' — order ' . $o['ref'], $cust, $owner);
}

/* ------------------------------------------------------------------ */
/* Stripe Checkout (cards + Apple Pay + Google Pay, hosted by Stripe)   */
/* ------------------------------------------------------------------ */

function stripe_enabled() {
    return setting('payment_mode') === 'stripe' && setting('stripe_sk') !== '' && function_exists('curl_init');
}

/** Creates a Stripe Checkout Session and returns its URL, or null on failure. */
function stripe_checkout_url($order, $success_url, $cancel_url, &$error = null) {
    $fields = [
        'mode'                 => 'payment',
        'success_url'          => $success_url,
        'cancel_url'           => $cancel_url,
        'customer_email'       => $order['customer']['email'],
        'client_reference_id'  => $order['id'],
    ];

    $i = 0;
    $cur = strtolower(setting('stripe_currency', 'usd'));
    foreach ($order['lines'] as $l) {
        $fields["line_items[$i][price_data][currency]"]             = $cur;
        $fields["line_items[$i][price_data][product_data][name]"]   = mb_substr($l['name'], 0, 120);
        $fields["line_items[$i][price_data][unit_amount]"]          = (int)round($l['price'] * 100);
        $fields["line_items[$i][quantity]"]                         = (int)$l['qty'];
        $i++;
    }
    foreach ([['Assembly and testing', $order['totals']['assembly']],
              ['Shipping',             $order['totals']['shipping']],
              ['Tax',                  $order['totals']['tax']]] as $extra) {
        if ($extra[1] > 0) {
            $fields["line_items[$i][price_data][currency]"]           = $cur;
            $fields["line_items[$i][price_data][product_data][name]"] = $extra[0];
            $fields["line_items[$i][price_data][unit_amount]"]        = (int)round($extra[1] * 100);
            $fields["line_items[$i][quantity]"]                       = 1;
            $i++;
        }
    }

    $ch = curl_init('https://api.stripe.com/v1/checkout/sessions');
    curl_setopt_array($ch, [
        CURLOPT_POST           => true,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_USERPWD        => setting('stripe_sk') . ':',
        CURLOPT_POSTFIELDS     => http_build_query($fields),
        CURLOPT_TIMEOUT        => 20,
    ]);
    $res  = curl_exec($ch);
    $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);

    $json = json_decode((string)$res, true);
    if ($code === 200 && !empty($json['url'])) return $json['url'];
    $error = $json['error']['message'] ?? 'Stripe did not accept the request.';
    return null;
}
