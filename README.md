# TafuraFlow

TafuraFlow is a restaurant ordering and operations system that runs as a plain HTML website on GitHub Pages. It does not require Node.js, npm, Vercel, or a build command.

**Tagline:** Every table, in sync.

## Release 1A

Release 1A strengthens the menu-to-service workflow:

- Preparation stations, with Kitchen and Bar created automatically and support for additional stations
- Category-level station routing and optional item-level routing overrides
- Modifier groups and options, including required choices, maximum selections, and price adjustments
- Live item availability: available, sold out, snoozed until a chosen time, or limited remaining portions
- Guest count when a table is opened
- Customer and staff-assisted order source tracking
- Duplicate-order protection, server-side price checks, quantity checks, and request throttling
- Typed guest requests for waiter, bill, water, cutlery, condiments, table clearing, or another need
- A dedicated kitchen/bar station board with ticket timers and selected options
- Immutable session, order, and order-item event history
- Selected options shown in customer order history, staff order views, KDS tickets, and final receipts
- Responsive phone layouts for the customer menu, Menu Operations, and station board

## Existing TafuraFlow features

- Super Admin company, owner, subscription, payment, suspension, and menu-design management
- Owner, manager, waiter, kitchen, bar, and cashier accounts
- Private invitation links for owners and staff
- Menu categories, ordered items, descriptions, prices, pictures, and restaurant-specific visual themes
- One-time QR codes for staff-opened table sessions
- Customer ordering, repeat ordering, cart, and current-session order history
- Waiter approval before preparation
- Staff-assisted ordering when a guest cannot scan the QR code
- Waiter assignment, live guest alerts, shared alert dismissal, and automatic page updates
- Discounts with usage limits, owner-controlled tax and service charges
- One final offline payment and printable receipt per table session
- Closed table links that can no longer be used

## Install Release 1A in Supabase

If your current TafuraFlow website and database are already working:

1. Open your Supabase project.
2. Open **SQL Editor** and select **New query**.
3. Open `supabase/migrations/20260808205304_release_1a_menu_service_foundations.sql` from this project. If you extracted the flat upload ZIP, open `tafuraflow-release-1a.sql` instead; it is the same file.
4. Copy the entire file into the SQL Editor.
5. Click **Run** once.

Do not run the Release 1A migration a second time after it succeeds. Supabase may need a few seconds to refresh its API schema after the migration.

For a completely new database, run these files in this order:

1. `20260718120000_initial_schema.sql`
2. `20260808205304_release_1a_menu_service_foundations.sql`

Only older installations that never received the invitations/company-billing upgrade need to run `20260718190000_invites_company_billing.sql` between those two files.

To make yourself Super Admin on a new installation, create your email and password in **Supabase > Authentication > Users**, then run:

```sql
update public.profiles
set platform_role = 'super_admin'
where lower(email) = lower('YOUR-EMAIL@example.com');
```

In **Authentication > URL Configuration**, set the Site URL to the GitHub Pages address, for example `https://dwtdhruvp246.github.io/restaurant-website/`.

## Upload Release 1A to GitHub Pages

The simplest method is:

1. Extract `TafuraFlow-Release-1A-Upload.zip`.
2. Open the `restaurant-website` repository on GitHub.
3. Upload every extracted file to the repository's top level.
4. Replace the older files when GitHub asks.
5. Commit the upload.

The prepared ZIP is flat: `index.html`, `styles.css`, `app.js`, and the other files all sit together. This avoids having to create an `assets` folder manually.

If GitHub Pages is not already enabled, open **Settings > Pages**, choose **Deploy from a branch**, select `main` and `/ (root)`, then save.

## Important Release 1A files

- `menu-foundations.html` — owner/manager Menu Operations page
- `stations.html` — kitchen/bar preparation station board
- `assets/menu-foundations.js` — stations, modifiers, routing, and item availability management
- `assets/stations.js` — KDS tickets, station filtering, timers, and preparation actions
- `assets/customer.js` — customer modifiers, service requests, order history, and duplicate protection
- `assets/app.js` — guest count, staff order views, receipt details, and shared operations
- `assets/core.js` — navigation, role routing, and friendly messages
- `assets/styles.css` — all desktop and phone layouts
- `supabase/migrations/20260808205304_release_1a_menu_service_foundations.sql` — Release 1A database, RLS policies, triggers, events, and secure functions

## Security note

The Supabase anon key in `assets/config.js` is designed to be public. TafuraFlow security is enforced by Row Level Security and the secure SQL functions. Never place a Supabase service-role key in an HTML or JavaScript file.
