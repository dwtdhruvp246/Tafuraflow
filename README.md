# TafuraFlow

TafuraFlow is a restaurant ordering and operations system that runs as a plain HTML website on GitHub Pages. It does not require Node.js, npm, Vercel, or a build command.

**Tagline:** Every table, in sync.

## Release 1A.1

Release 1A.1 adds Shared Waiter Mode for restaurants that use a small number of shared tablets:

- One dedicated restaurant tablet account remains signed in to TafuraFlow
- Each waiter chooses their name and enters a private four-number PIN
- PIN-only waiters do not need an email address or individual Supabase Auth account
- The active waiter's name is recorded on opened tables, assisted orders, status changes, voids, discounts, payments, and guest-request actions
- A visible **Switch waiter** button safely returns the tablet to the waiter selection screen
- The tablet automatically locks back to waiter selection after 15 minutes without activity
- Five incorrect attempts temporarily lock that waiter PIN; repeated attempts also lock the device for 15 minutes
- Owners manage waiter names, phone numbers, PINs, activation, and shared tablet accounts from the Staff page

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

After Release 1A is installed, run `supabase/migrations/20260809100116_shared_waiter_mode.sql` once to install Shared Waiter Mode. In the flat upload ZIP, this same file is named `tafuraflow-release-1a1.sql`.

To make yourself Super Admin on a new installation, create your email and password in **Supabase > Authentication > Users**, then run:

```sql
update public.profiles
set platform_role = 'super_admin'
where lower(email) = lower('YOUR-EMAIL@example.com');
```

In **Authentication > URL Configuration**, set the Site URL to the GitHub Pages address, for example `https://dwtdhruvp246.github.io/restaurant-website/`.

## Set up a shared waiter tablet

1. On the Owner **Staff** page, invite one dedicated waiter account for the tablet. Use a restaurant-controlled email, for example `tablet1@yourrestaurant.com`, and name it **Shared Waiter Tablet**.
2. Complete that account's invitation on the physical tablet and sign in once with its email and password.
3. From an owner account, return to **Staff** and choose **Use as shared tablet** for that dedicated account.
4. Add each real waiter under **Tablet waiters**, including their name, phone number if needed, and a four-number PIN.
5. The tablet will now show the waiter selection page. A waiter taps their name, enters their PIN, and uses TafuraFlow normally.
6. Before handing the tablet to another waiter, tap **Switch waiter**. Use **Sign out device** only when removing the tablet from service.

Do not use an owner's account as the shared tablet account. The dedicated device account should have the waiter role and should not represent a real person.

## Upload Release 1A.1 to GitHub Pages

The simplest method is:

1. Extract `TafuraFlow-Release-1A.1-Upload.zip`.
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
- `waiter-login.html` and `assets/waiter-terminal.js` — shared tablet waiter selection and PIN entry
- `supabase/migrations/20260809100116_shared_waiter_mode.sql` — Release 1A.1 PIN security, waiter attribution, secure functions, and RLS updates

## Security note

The Supabase anon key in `assets/config.js` is designed to be public. TafuraFlow security is enforced by Row Level Security and the secure SQL functions. Never place a Supabase service-role key in an HTML or JavaScript file.
