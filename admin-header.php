<?php
require_once __DIR__ . '/config.php';
require_admin();
$s = settings();
$here = basename($_SERVER['PHP_SELF']);
?><!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title><?= e(($title ?? 'Admin') . ' — ' . $s['site_name']) ?></title>
<meta name="robots" content="noindex">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Archivo:wght@400;500;600;700;800&family=IBM+Plex+Mono:wght@400;500;600&display=swap" rel="stylesheet">
<link rel="stylesheet" href="../assets/css/style.css">
</head>
<body>
<header class="masthead">
  <div class="shell">
    <a class="brand" href="dashboard.php"><span class="brand-mark" aria-hidden="true"></span><?= e($s['site_name']) ?> admin</a>
    <nav class="nav">
      <a href="../index.php">View the site</a>
      <a href="logout.php">Sign out</a>
    </nav>
  </div>
</header>

<div class="shell admin-wrap">
  <nav>
    <ul class="admin-nav">
      <?php
      $links = ['dashboard.php'=>'Dashboard','products.php'=>'Products','parts.php'=>'Build parts','orders.php'=>'Orders','messages.php'=>'Messages','settings.php'=>'Settings'];
      foreach ($links as $file => $label):
      ?><li><a class="<?= $here === $file ? 'on' : '' ?>" href="<?= $file ?>"><?= e($label) ?></a></li><?php endforeach; ?>
    </ul>
  </nav>
  <main>
    <?php if ($f = flash()): ?><div class="notice notice-ok"><?= e($f) ?></div><?php endif; ?>
