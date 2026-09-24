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
