# Tech shop site — setup guide

A complete PHP site: products, a PC build configurator with CPU-based part matching,
a cart, checkout, order emails, a tech-request form, and an admin area where you edit
everything without touching code.

No database. All content lives in JSON files under `/data`.

---

## 1. Put it online

Upload the whole folder to your web host's public directory (`public_html`,
`www`, or similar). You need **PHP 7.4 or newer**. Almost any shared host qualifies.

Make these two folders writable — in cPanel's file manager, set permissions to `755`
(or `775` if 755 doesn't work):

```
/data
/uploads
```

If the site loads but nothing saves, this is nearly always the reason.

## 2. Log in

Open `includes/config.php` and change these two lines to whatever you want:

```php
define('ADMIN_USERNAME',         'owner');
define('ADMIN_DEFAULT_PASSWORD', 'ChangeMe123!');
```

Then go to `yoursite.com/admin/login.php` and sign in with them.

The first time you log in, that password gets hashed and stored in `data/settings.json`.
From then on the file is what counts, and you change the password from
**Settings → Change your password**. The username stays in `config.php`.

**Change the default password before the site goes public.**

## 3. Fill in your details

Everything below is in **Admin → Settings** and takes effect immediately:

- Business name, tagline, phone, address, hours
- **Your email address** — this is where every order, contact message and tech
  request gets sent, with the parts list, the customer's shipping address and
  their email address. Nothing works properly until this is filled in.
- Assembly fee (starts at $250) and a switch to turn the build option on or off
- Tax rate, flat shipping, currency symbol
- The full text of the About page and the intro on the Contact page

## 4. Add products and parts

**Admin → Products** is your general catalogue — anything you sell off the shelf.
Name, price, description, photo, stock count, and a tick box to feature it on the
home page.

**Admin → Build parts** feeds the *Build a PC* page. Alongside the name and price
there are spec fields, and these are what drive the automatic recommendations:

| Field | Put it on | What it does |
|---|---|---|
| Socket | Processors, motherboards, coolers | Boards with a different socket are ruled out. Coolers can list several, comma separated. |
| Generation | Anything | Parts tagged with the same generation as the chosen CPU get flagged as a match. |
| Memory type | Motherboards, memory | DDR4 memory is ruled out once a DDR5 board is picked, and vice versa. |
| Form factor | Motherboards, cases | Cases too small for the chosen board are ruled out. Cases can list several sizes. |
| Power draw / cooler rating | Processors, coolers | A cooler rated below the CPU's draw is ruled out. |
| Supply output / card draw | Power supplies, graphics cards | Supplies too small for the estimated total draw are ruled out. |

Leave any field blank and that particular check is simply skipped — so you can start
rough and tighten it up later.

**How it looks to a customer:** they pick a processor, and every slot below re-sorts
itself. Compatible parts jump to the top with a green note explaining why they fit
("Socket matches your Ryzen 7 7800X3D"). Incompatible parts grey out with a note
saying what's wrong. The running total and estimated wattage update as they go.

Start by adding two or three processors. Everything else keys off them.

## 5. Taking payment — read this part

**The site does not collect card numbers, and it should not.** Typing a card number
into a form on your own server puts you under PCI-DSS compliance rules, and no bank
will accept a card charge sent directly from a custom script. That route doesn't work,
regardless of how it's built.

What works is a payment processor. This site is wired for **Stripe**:

1. Sign up at stripe.com and connect your bank account in their dashboard. This is
   where you set where the money lands — not on this website.
2. Copy your publishable key (`pk_live_…`) and secret key (`sk_live_…`) from the
   Stripe dashboard into **Settings → Taking payment**.
3. Set payment method to **Stripe** and save.

Customers now go to Stripe's own hosted page to pay. Card, Apple Pay and Google Pay
all work, with no extra setup for Apple Pay beyond verifying your domain in Stripe.
Stripe deposits your takings on a rolling schedule. Your server never sees a card
number, so PCI compliance isn't your problem.

Until you do that, the site runs in **invoice mode**: customers place the order,
you get the full email, and you bill them however you like.

**One caveat on Stripe:** an order is marked paid when the customer returns from
Stripe's page. That's fine for a small shop, but if you start doing volume, ask a
developer to add a Stripe webhook (`checkout.session.completed`) so payment status
comes from Stripe directly rather than from the browser redirect.

## 6. Email

The site uses PHP's built-in `mail()`. On most shared hosts this works out of the box.
Two things make the difference between landing in the inbox and landing in spam:

- Set **Send mail from** to an address on your own domain, not a Gmail address.
- Ask your host to confirm SPF and DKIM records are set for your domain.

If mail doesn't arrive at all, everything is still recorded — contact and tech
requests under **Admin → Messages**, orders under **Admin → Orders**, where you can
also re-send any order email.

---

## What's where

```
index.php            Home page
products.php         Catalogue, search and filter, add to cart
build-pc.php         PC configurator with compatibility matching
request-tech.php     Tech request form
about.php            About (text comes from Settings)
contact.php          Contact form
cart.php             Cart, quantities, assembly toggle
checkout.php         Address capture, then Stripe or invoice
order-complete.php   Confirmation, marks Stripe orders paid

admin/login.php      Your login
admin/dashboard.php  Overview
admin/products.php   Add and edit products
admin/parts.php      Add and edit build parts
admin/orders.php     Orders, status, re-send email
admin/messages.php   Contact and tech-request log
admin/settings.php   Everything else

includes/config.php  Your username and default password
data/*.json          All your content. Back this folder up.
uploads/             Product photos
```

## Security notes

- `/data` and `/uploads` ship with `.htaccess` rules blocking web access and PHP
  execution. **These only work on Apache.** On Nginx, add the equivalent to your
  server block, or the `data` folder — which holds your password hash and your
  Stripe secret key — will be readable by anyone who guesses the URL:

  ```nginx
  location ~ ^/(data|includes)/ { deny all; return 404; }
  location ~ ^/uploads/.*\.(php|phtml|phar)$ { deny all; }
  ```

- Get an SSL certificate so the site runs on `https://`. Most hosts give one free
  through Let's Encrypt. Logging into an admin panel over plain `http` sends your
  password across the network in the clear.
- Back up `/data` and `/uploads`. That's your entire site content.

### Private product notes (PR #94)

Apply `supabase/migrations/202611110001_private_product_notes.sql` after the staff workspace and 20261110 migrations. It was applied successfully to the production project on 2026-11-11. The migration adds private notes for all 721 unique catalog IDs without replacing existing content; owner workspace refresh creates notes for future listings.

In Employees → Roles / permissions, set **View product notes** and **Edit product notes** independently. Both default to disabled. Editing requires viewing. Product-note permissions are separate from general internal-note permissions and are enforced by the database for filtered/unfiltered reads and all writes. Only the owner can create, delete, retarget or change product-note access. Product permissions grant access to product notes; role audience lists continue to apply to other internal notes.

Notes include an Apex product link, plus the Newegg source when the catalog records one. Missing Newegg URLs are explicitly labeled and never guessed. Existing private text is preserved. Notes and employee permission overrides are never stored in public `data.json`.

Validation: `PGLITE_MODULE=/path/to/@electric-sql/pglite/dist/index.js node tests/staff-permissions.mjs` and `node tests/staff-workspace-state.mjs`.

### Employee commissions and owner overview

Apply `supabase/migrations/202611110004_commissions_dashboard.sql` after the contribution settlement migration. Owner-set commissions use integer USD cents, require revision checks on edits, and preserve the amount and optional payment reference in settlement history. `Paid employee` records a payment already made; it does not transfer money. Old paid contributions without an amount stay labeled unknown. Test commissions are excluded from real balances.

Staff workspace now opens the owner overview. Sales contributions has Outstanding, Employee payment history, and Voided views. Employee details show unpaid balances and paid counts. Customer links can be filtered by waiting, submitted/awaiting payment, paid, completed test and expired states; unused valid links retain their copy button. No reminders or customer messages are sent automatically.

Additional checks: `node tests/market-link-filters.mjs` and `node tests/staff-workspace-state.mjs`, plus the full PGlite staff-permissions integration test.

### Private customer order tracking

Apply `supabase/migrations/202611110005_customer_tracking.sql` after the staff/checkout migrations. New checkouts generate a random 256-bit private link and retain only its reference/token in this browser. Confirmation and Track order pages expose the link; owner tests return one too. Existing orders receive private links the owner can copy from Orders & requests → Customer progress / tracking link.

The public status RPC requires the complete random token and returns only the reference, item names/quantities, total, payment confirmation, customer-visible stage/message and recorded updates. It never uses an email address, order reference or the legacy local customer profile as authentication. Contact details, shipping addresses, internal notes, employee details and payment identifiers are excluded. Anyone given the link can view that limited status information, so it should be shared privately.

Owners and assigned employees with orders/update-status permissions can update customer progress. Existing working/shipped/delivered status actions synchronize progress. Customer-facing fulfillment cannot start before payment confirmation (except clearly labeled owner tests). Deleting the source inbox order preserves the last limited tracking snapshot as archived; it does not fabricate delivery. No customer emails are sent automatically by this feature. Existing owner-triggered status emails include the tracking link.

Checks: `node tests/order-tracking-state.mjs` and the full PGlite staff-permissions suite cover token access, response redaction, assignment/permission checks, stale edits, unpaid/test behavior, archived snapshots and existing workflows.

### Build compatibility and final review

`build-compatibility.js` contains the active static storefront checks. Socket and DDR-generation conflicts, explicit case clearances, listed radiator sizes/thickness, PSU minimum draw and known connector quantities are checked against catalog fields. Unknown measurements, CPU-model/BIOS support, cable counts/standards and storage interface/lanes remain visibly unverified. A matching socket alone is not a CPU-support guarantee. Optional PSU safety headroom is a recommendation; output below the catalog draw is a blocking conflict.

Review build before cart opens a final component/price list, known conflicts, unverified warnings, power estimate, assembly fee, and an estimated combined cart total including configured shipping/tax. Known conflicts block confirmation; unknowns and partial loose-part selections require acknowledgment. Assembled selections must include the essential components and selected or verified included cooling. Review is repeated if selection, metadata, prices, assembly, margin or cart contents change. Existing product metadata is preserved when editing the product so specifications and source details are not lost.

The checks are catalog-based guidance, not manufacturer validation or a full system peak-power calculation. No unsupported measurements have been filled in, and no products/prices were changed. Current shipping/tax and promo discounts are finalized during checkout. No database or Edge Function deployment is required for this change.

Run `node tests/build-compatibility.mjs` for socket/memory/clearance/radiator/connector/power cases, candidate replacement, missing data, partial assembly requirements, review acknowledgments and stale-price/cart-total validation.
