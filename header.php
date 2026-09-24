<?php
require_once __DIR__ . '/config.php';
$page = $page ?? '';
$s = settings();
?><!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title><?= e(($title ?? '') ? $title . ' — ' . $s['site_name'] : $s['site_name']) ?></title>
<meta name="description" content="<?= e($s['tagline']) ?>">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Archivo:wght@400;500;600;700;800&family=IBM+Plex+Mono:wght@400;500;600&display=swap" rel="stylesheet">
<link rel="stylesheet" href="assets/css/style.css">
</head>
<body>

<header class="masthead">
  <div class="shell">
    <a class="brand" href="index.php"><span class="brand-mark" aria-hidden="true"></span><?= e($s['site_name']) ?></a>
    <nav class="nav">
      <a href="products.php"     <?= $page==='products'?'aria-current="page"':'' ?>>Parts &amp; products</a>
      <a href="build-pc.php"     <?= $page==='build'?'aria-current="page"':'' ?>>Build a PC</a>
      <a href="request-tech.php" <?= $page==='tech'?'aria-current="page"':'' ?>>Request a tech</a>
      <a href="about.php"        <?= $page==='about'?'aria-current="page"':'' ?>>About</a>
      <a href="contact.php"      <?= $page==='contact'?'aria-current="page"':'' ?>>Contact</a>
      <a class="cart-pill" href="cart.php">Cart <?= cart_count() ?></a>
    </nav>
  </div>
</header>

<?php if (is_admin()): ?>
<div class="adminbar">
  <div class="shell">
    <span>Signed in as <?= e(ADMIN_USERNAME) ?></span>
    <a href="admin/dashboard.php">Dashboard</a>
    <a href="admin/products.php">Products</a>
    <a href="admin/parts.php">Build parts</a>
    <a href="admin/orders.php">Orders</a>
    <a href="admin/settings.php">Settings</a>
    <a href="admin/logout.php">Sign out</a>
  </div>
</div>
<?php endif; ?>

<?php if ($f = flash()): ?>
<div class="shell" style="padding-top:20px"><div class="notice notice-ok"><?= e($f) ?></div></div>
<?php endif; ?>
