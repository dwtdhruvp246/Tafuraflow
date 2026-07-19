# DineQR

DineQR is a plain HTML restaurant ordering and operations website. It works on GitHub Pages without Node.js, npm, Vercel, or a build command.

## What is included

- Super Admin creates restaurant companies and private owner invitation links
- Super Admin can edit, suspend, activate, or delete companies
- Super Admin manually records payments received from restaurant owners
- Super Admin can open each company's owner-payment history
- Owner, manager, waiter, kitchen, and cashier accounts
- Company name appears in staff and customer pages
- Editable menu categories and items with descriptions, USD prices, and uploaded pictures
- Owner-controlled category order and item order inside each category
- Staff-created tables and one-time table-session QR codes
- Owners and managers can edit/delete tables and view current table orders
- Customer menu, quantities, cart, repeat ordering, waiter request, and bill request
- Waiter approval before an order moves to the kitchen
- Order preparation, ready, served, rejected, and item voiding with a reason
- Owner-created percentage or fixed-dollar discounts
- Owner-controlled tax and service charge
- One final offline payment per table session and printable receipt
- Closing a table permanently disables that session's QR link

## The only two setup jobs

### 1. Set up Supabase

1. Open your Supabase project.
2. Click **SQL Editor** and then **New query**.
3. Open `supabase/migrations/20260718120000_initial_schema.sql` from this project.
4. Copy the entire SQL file, paste it into Supabase, and click **Run**. Run it once on a new database.
5. In Supabase, open **Authentication → Users → Add user** and create your own Super Admin email and password.
6. Return to the Supabase SQL Editor and run this, using the same email:

```sql
update public.profiles
set platform_role = 'super_admin'
where lower(email) = lower('YOUR-EMAIL@example.com');
```

7. Sign in at `index.html`. You can now add the first company and its owner. DineQR gives you a private invitation link to send to that owner.

If you already ran the earlier DineQR SQL, do not run the complete schema again. Instead, run `supabase/migrations/20260718190000_invites_company_billing.sql`. The upgrade also repairs workflow permissions and is safe to run again when you receive a newer DineQR package.

If Supabase requires email confirmation, confirm the email before signing in. In **Authentication → URL Configuration**, set the Site URL to your GitHub Pages address, for example `https://dwtdhruvp246.github.io/restaurant-website/`.

### 2. Upload to GitHub Pages

The easiest method is to extract `DineQR-Upload-These-Files.zip` and upload **everything inside it** directly into the top level of the `restaurant-website` repository. Replace the older files when GitHub asks.

If you are uploading from the development folder instead, upload all of these:

- every `.html` file
- the complete `assets` folder
- `README.md`
- the `supabase` folder (kept there as your database setup backup)

The important point is that `index.html` must be visible on the first repository screen, not placed inside another folder.

Then open **Settings → Pages**, choose **Deploy from a branch**, select the `main` branch and `/ (root)`, and save. No GitHub Action and no Node.js are required.

## What the files do

- `index.html` — staff login page and the page GitHub Pages opens first
- `signup.html` — private-link-only account creation for invited owners and staff
- `forgot-password.html` / `reset-password.html` — password recovery
- `dashboard.html` — Super Admin or restaurant overview
- `companies.html` — Super Admin company and owner setup
- `admin-finance.html` — Super Admin manual restaurant-owner payment records
- `tables.html` — tables, session opening, QR printing, payments, and final receipts
- `orders.html` — waiter approval and kitchen order workflow
- `menu.html` — menu category and item management
- `staff.html` — staff invitations and access management
- `finance.html` — receipt history, revenue, and discounts
- `settings.html` — company name, tax, and service charge
- `customer.html` — secure customer menu reached by scanning a table QR code
- `session-ended.html` — shown after the table has closed
- `waiting.html` — shown when an account has not yet been assigned to a company
- `assets/styles.css` — all website design and mobile layout
- `assets/config.js` — the public Supabase URL and anon key
- `assets/core.js` — shared login, layout, navigation, and helper code
- `assets/auth.js` — sign-in, sign-up, and password reset logic
- `assets/app.js` — restaurant and Super Admin functionality
- `assets/customer.js` — customer menu, cart, ordering, and requests
- `supabase/migrations/20260718120000_initial_schema.sql` — complete database, permissions, and secure functions
- `supabase/migrations/20260718190000_invites_company_billing.sql` — upgrade for an existing DineQR database

The Supabase anon key in `assets/config.js` is intended to be public. Security is enforced by the SQL row-level security policies. Never put a Supabase service-role key in an HTML or JavaScript file.
