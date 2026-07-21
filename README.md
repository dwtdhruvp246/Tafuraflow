# TafuraFlow

TafuraFlow is a plain HTML restaurant ordering and operations website. It works on GitHub Pages without Node.js, npm, Vercel, or a build command.

**Tagline:** Every table, in sync.

## What is included

- Super Admin creates restaurant companies and private owner invitation links
- Super Admin can edit company and owner details, suspend, activate, expire, or delete companies
- Super Admin manually records and edits payments received from restaurant owners, including the paid access expiry date
- Super Admin can open each company's owner-payment history
- Owner, manager, waiter, kitchen, bar, and cashier accounts
- Company name appears in staff and customer pages
- Editable menu categories and items with descriptions, USD prices, and uploaded pictures
- Owner-controlled category order and item order inside each category, with each category routed to the kitchen or bar
- Super Admin-controlled, restaurant-specific customer-menu themes, colors, fonts, headers, category navigation, item cards, image shapes, hero layouts, backgrounds, branding, contact details, and visibility controls
- Each restaurant's customer-menu design can be saved once every 365 days
- Staff-created tables and one-time table-session QR codes
- Owner, manager, or waiter ordering from an open table's Menu button when guests cannot scan the QR code
- Owners and managers can edit/delete tables and view current table orders
- Customer menu, quantities, cart, repeat ordering, current-session order history, waiter request, and bill request
- Live table-number popups on waiter and cashier screens for waiter calls and bill requests
- Shared popup resolution: dismissing a guest alert on either a waiter or cashier screen resolves it everywhere immediately and allows the customer to send a fresh request
- Automatic live updates across tables, orders, menus, staff, receipts, company records and settings without manually refreshing the browser
- Waiter approval before preparation, independent kitchen/bar item progress, waiter assignment, and fulfilled-order details
- Dedicated kitchen and bar live-order screens plus preparation-area order history
- Order preparation, ready, served, rejected, and item voiding with a reason
- Owner-created percentage or fixed-dollar discounts with optional usage limits and remaining-use tracking
- Owner-controlled tax and service charge
- One final offline payment per table session and detailed printable receipt with the assigned waiter
- Closing a table permanently disables that session's QR link

## The only two setup jobs

### 1. Set up Supabase

1. Open your Supabase project.
2. Click **SQL Editor** and then **New query**.
3. Open `supabase/migrations/20260718120000_initial_schema.sql` from this project.
4. Copy the entire SQL file, paste it into Supabase, and click **Run**. Run it once on a new database.
5. In Supabase, open **Authentication â†’ Users â†’ Add user** and create your own Super Admin email and password.
6. Return to the Supabase SQL Editor and run this, using the same email:

```sql
update public.profiles
set platform_role = 'super_admin'
where lower(email) = lower('YOUR-EMAIL@example.com');
```

7. Sign in at `index.html`. You can now add the first company and its owner. TafuraFlow gives you a private invitation link to send to that owner.

If you already ran the earlier TafuraFlow SQL, do not run the complete schema again. Instead, run `supabase/migrations/20260718190000_invites_company_billing.sql`. The upgrade also repairs workflow permissions and is safe to run again when you receive a newer TafuraFlow package.

If Supabase requires email confirmation, confirm the email before signing in. In **Authentication â†’ URL Configuration**, set the Site URL to your GitHub Pages address, for example `https://dwtdhruvp246.github.io/restaurant-website/`.

### 2. Upload to GitHub Pages

The easiest method is to extract `TafuraFlow-Upload-These-Files.zip` and upload **every file inside it** directly into the top level of the `restaurant-website` repository. This ZIP is specially prepared as a flat GitHub upload: `styles.css`, `app.js`, `core.js`, and the other shared files are beside `index.html`, so no folder creation is required. Replace the older files when GitHub asks.

If you are uploading from the development folder instead, upload all of these:

- every `.html` file
- the complete `assets` folder
- `README.md`
- the `supabase` folder (kept there as your database setup backup)

The important point is that `index.html`, `styles.css`, `app.js`, `core.js`, `auth.js`, `customer.js`, and `config.js` must all be visible on the first repository screen, not placed inside another folder. The HTML files inside the ZIP already point to these root-level files.

Then open **Settings â†’ Pages**, choose **Deploy from a branch**, select the `main` branch and `/ (root)`, and save. No GitHub Action and no Node.js are required.

## What the files do

- `index.html` â€” staff login page and the page GitHub Pages opens first
- `signup.html` â€” private-link-only account creation for invited owners and staff
- `forgot-password.html` / `reset-password.html` â€” password recovery
- `dashboard.html` â€” Super Admin or restaurant overview
- `companies.html` — Super Admin company and owner setup, payment history, and annual customer-menu design control
- `admin-finance.html` â€” Super Admin manual restaurant-owner payment records
- `tables.html` â€” tables, session opening, QR printing, staff-assisted menu ordering, payments, and final receipts
- `orders.html` â€” waiter approval and kitchen order workflow
- `bar-orders.html` â€” live drink orders routed to the bar account
- `order-history.html` â€” previous kitchen or bar orders with full details
- `menu.html` â€” menu category and item management
- `staff.html` — staff invitations, owner-only staff detail editing, and access management
- `finance.html` â€” receipt history, revenue, and discounts
- `settings.html` — owner-controlled tax and service charge (company name and customer-menu design are Super Admin controlled)
- `customer.html` â€” secure customer menu reached by scanning a table QR code
- `session-ended.html` â€” shown after the table has closed
- `waiting.html` â€” shown when an account has not yet been assigned to a company
- `assets/styles.css` â€” all website design and mobile layout
- `assets/config.js` â€” the public Supabase URL and anon key
- `assets/core.js` â€” shared login, layout, navigation, and helper code
- `assets/auth.js` â€” sign-in, sign-up, and password reset logic
- `assets/app.js` â€” restaurant and Super Admin functionality
- `assets/customer.js` â€” customer menu, cart, ordering, and requests
- `supabase/migrations/20260718120000_initial_schema.sql` â€” complete database, permissions, and secure functions
- `supabase/migrations/20260718190000_invites_company_billing.sql` â€” upgrade for an existing TafuraFlow database

The Supabase anon key in `assets/config.js` is intended to be public. Security is enforced by the SQL row-level security policies. Never put a Supabase service-role key in an HTML or JavaScript file.
