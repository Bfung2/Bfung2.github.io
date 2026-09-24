<footer class="foot">
  <div class="shell">
    <div class="foot-grid">
      <div>
        <h4><?= e(setting('site_name')) ?></h4>
        <p style="margin:0"><?= e(setting('tagline')) ?></p>
      </div>
      <div>
        <h4>Shop</h4>
        <ul>
          <li><a href="products.php">Parts &amp; products</a></li>
          <li><a href="build-pc.php">Build a PC</a></li>
          <li><a href="cart.php">Cart</a></li>
        </ul>
      </div>
      <div>
        <h4>Get in touch</h4>
        <ul>
          <li><a href="request-tech.php">Request a tech</a></li>
          <li><a href="contact.php">Contact</a></li>
          <?php if (setting('phone')): ?><li><?= e(setting('phone')) ?></li><?php endif; ?>
          <?php if (setting('address')): ?><li><?= e(setting('address')) ?></li><?php endif; ?>
          <li><?= is_admin() ? '<a href="admin/dashboard.php">Dashboard</a>' : '<a href="admin/login.php">Staff login</a>' ?></li>
        </ul>
      </div>
    </div>
    <div class="foot-base">&copy; <?= date('Y') ?> <?= e(setting('site_name')) ?></div>
  </div>
</footer>
</body>
</html>
