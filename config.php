<?php
/* =====================================================================
   CONFIG  —  This is the only file you need to touch by hand.
   ===================================================================== */

// -------- YOUR LOGIN --------------------------------------------------
// Change these two lines to whatever you want. This is your admin login.
// After your first successful login the password is hashed and stored in
// data/settings.json, and you can change it from Admin > Settings.
define('ADMIN_USERNAME',         'owner');
define('ADMIN_DEFAULT_PASSWORD', 'ChangeMe123!');

// -------- BASICS ------------------------------------------------------
define('DATA_DIR',   __DIR__ . '/../data');
define('UPLOAD_DIR', __DIR__ . '/../uploads');
define('UPLOAD_URL', 'uploads');

// Set to true only while you are testing, so PHP errors show on screen.
define('DEBUG', false);

// ---------------------------------------------------------------------
if (DEBUG) { ini_set('display_errors', 1); error_reporting(E_ALL); }
if (session_status() === PHP_SESSION_NONE) {
    session_set_cookie_params(['httponly' => true, 'samesite' => 'Lax']);
    session_start();
}
require_once __DIR__ . '/functions.php';
