<?php
require_once __DIR__ . '/../includes/config.php';
$error = '';

if (is_admin()) redirect('dashboard.php');

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    check_csrf();
    // Simple brute-force slowdown.
    $_SESSION['tries'] = ($_SESSION['tries'] ?? 0) + 1;
    if ($_SESSION['tries'] > 6) { sleep(min(10, $_SESSION['tries'])); }

    if (attempt_login(post('username'), $_POST['password'] ?? '')) {
        unset($_SESSION['tries']);
        redirect('dashboard.php');
    }
    $error = 'That username and password combination did not work.';
}
$s = settings();
?><!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Sign in — <?= e($s['site_name']) ?></title>
<meta name="robots" content="noindex">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Archivo:wght@400;500;600;700;800&family=IBM+Plex+Mono:wght@400;500;600&display=swap" rel="stylesheet">
<link rel="stylesheet" href="../assets/css/style.css">
</head>
<body>
<div class="login-box">
  <h1 style="font-size:1.6rem">Sign in</h1>
  <p class="muted" style="font-size:.9rem">Staff access for <?= e($s['site_name']) ?>.</p>
  <?php if ($error): ?><div class="notice notice-bad"><?= e($error) ?></div><?php endif; ?>
  <form method="post">
    <?= csrf_field() ?>
    <div class="field"><label for="u">Username</label><input id="u" type="text" name="username" autocomplete="username" required autofocus></div>
    <div class="field"><label for="p">Password</label><input id="p" type="password" name="password" autocomplete="current-password" required></div>
    <button class="btn" type="submit" style="width:100%">Sign in</button>
  </form>
  <p style="margin-top:20px"><a class="mono" href="../index.php">Back to the site</a></p>
</div>
</body>
</html>
