# TafuraFlow

TafuraFlow is a restaurant ordering and operations system that runs as a plain HTML website on GitHub Pages. It does not require Node.js, npm, Vercel, or a build command.

**Tagline:** Every table, in sync.

## Release 3

Release 3 adds the financial close and workforce controls needed for accountable daily restaurant operations:

- Staff schedules, self clock-in/out, actual hours, break minutes, shift tasks, and a manager handover logbook
- Cashier shifts with opening float, cash-ins, paid-outs, refunds, adjustments, counted cash, and variance
- Payments automatically linked to the cashier's currently open till
- Business-day closing that refuses to lock until all tables are closed and every till is reconciled
- Immutable day-close snapshots covering sales, payments, expected cash, counted cash, and variance
- Manager approval requests and decisions for discounts, voids, refunds, payment corrections, cash adjustments, and day reopening
- Restaurant-specific manager thresholds for controlled actions
- Split bills by equal share or by ordered item, with one payment per guest bill and automatic table closure after the final split is paid
- Advanced reports for daily/hourly sales, payment methods, tables, waiters, menu items, discounts, voids, cash shifts, and staff attendance
- CSV export and printable management reports

### Install Release 3

Release 3 requires Release 2 and every earlier migration.

1. Open Supabase **SQL Editor** and create a new query.
2. Copy all of `supabase/migrations/20260813110000_release_3_financial_staff_operations.sql` into it. In the flat upload ZIP, this is `tafuraflow-release-3.sql`.
3. Click **Run** once. Do not run the Release 3 SQL again after it succeeds.
4. Extract `TafuraFlow-Release-3-Upload.zip` and upload every extracted file to the top level of the GitHub repository, replacing the older files.
5. Sign in as owner or manager and open **Daily operations**, **Approvals**, **Split bills**, and **Reports**.

Install the SQL before uploading the new website files. Existing normal table checkout continues to work; use **Split bills** only for tables that need separate guest payments.

## Release 2

Release 2 adds live floor control, waiter ownership, advanced preparation timing, and service-performance reporting:

- Visual floor areas with restaurant tables positioned on a room canvas
- Live table states for available, seated, ordered, preparing, ready to serve, and bill requested
- Guest count, elapsed table time, assigned waiter, live bill total, and ready-item count on the floor
- A responsive **My floor** list for waiter phones and shared tablets
- Manager-defined waiter sections with table membership and an assigned waiter
- Manager table transfers with a required reason, waiter reassignment, and permanent transfer history
- KDS tickets separated into New, Preparing, and Ready lanes
- Ticket acknowledgement, item timing timestamps, warning/overdue thresholds, and Rush/VIP priority
- Persistent ready alerts for the assigned waiter
- Kitchen and bar sold-out controls connected to customer menu availability
- Item-by-item preparation status in the customer's **My orders** view
- Service analytics for covers, table time, preparation time, overdue tickets, guest-response time, stations, and waiters

### Install Release 2

Release 2 requires all Release 1 files, including Release 1B. After Release 1B has succeeded:

1. Open Supabase **SQL Editor** and create a new query.
2. Copy all of `supabase/migrations/20260812110000_release_2_floor_service_advanced_kds.sql` into it. In the flat upload ZIP, this is `tafuraflow-release-2.sql`.
3. Click **Run** once. Do not run the Release 2 SQL again after it succeeds.
4. Extract `TafuraFlow-Release-2-Upload.zip` and upload every extracted file to the top level of the GitHub repository, replacing the old website files.
5. Sign in as an owner or manager, open **Floor**, arrange tables, and create waiter sections.

Install the SQL before uploading the Release 2 website files. Otherwise the new pages will report that the database update is missing.

## Release 1B

Release 1B adds the business and payment foundation required for Zimbabwe-first restaurant operations:

- A default branch for every existing restaurant, with branch IDs backfilled across operational records
- Africa/Harare timezone and a configurable late-night business-day cutoff
- Automatically opened business dates that owners or managers can close after all tables are closed
- USD as the default bill currency, with optional ZiG (ZWG) recording and a branch-maintained conversion rate
- Cash USD, Cash ZiG, Card, EcoCash, InnBucks, ZIPIT, bank transfer, and other offline payment methods
- Payment references and received-currency details on receipts
- Bills, bill lines, payments, and payment allocations, while the current screen still records one final payment
- Permission definitions, staff overrides, approval-request foundations, and immutable financial events
- Per-table public order/request limits and owner/manager suspicious-activity review
- A new responsive **Business** page for branch, currency, payment-method, business-day, and security controls

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
- Direct customer-order routing to the configured Kitchen or Bar station
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

If Release 1A.1 was installed before 9 August 2026 and adding a PIN waiter reports that the database update is missing, do not rerun the full release. Run `supabase/migrations/20260809105855_fix_shared_waiter_extension_schema.sql` once instead. In the flat ZIP it is named `tafuraflow-release-1a1-repair.sql`. This connects the secured waiter functions to Supabase's `extensions` schema and refreshes the API schema cache.

To restrict waiter order history, run `supabase/migrations/20260809195328_restrict_waiter_fulfilled_order_history.sql` once. In the flat ZIP it is named `tafuraflow-waiter-order-history.sql`. Waiters will continue seeing live service orders, but served and rejected orders are only visible to the waiter assigned to that table. Owners, managers, kitchen, bar and cashier retain their existing access.

If the waiter Orders page shows a permission screen after installing the first waiter-history SQL, run `supabase/migrations/20260809200244_fix_waiter_order_history_login_link.sql` once. In the flat ZIP it is named `tafuraflow-waiter-order-history-repair.sql`. This connects the selected personal or shared-PIN waiter login to the table assignment without blocking the live Orders page.

To remove waiter order approval and route new orders directly to Kitchen or Bar, run `supabase/migrations/20260809201204_auto_accept_and_route_orders.sql` once. In the flat ZIP it is named `tafuraflow-direct-order-routing.sql`. It also releases existing pending orders and routes each item using its menu station assignment.

After all Release 1A and 1A.1 files above are installed, run `supabase/migrations/20260811085036_release_1b_business_payment_foundations.sql` once. In the flat ZIP it is named `tafuraflow-release-1b.sql`. Do not run Release 1B before the earlier migrations because it backfills their tables and waiter attribution fields.

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

## Upload the latest TafuraFlow files to GitHub Pages

The simplest method is:

1. Extract `TafuraFlow-Release-3-Upload.zip`.
2. Open the `restaurant-website` repository on GitHub.
3. Upload every extracted file to the repository's top level.
4. Replace the older files when GitHub asks.
5. Commit the upload.

The prepared ZIP is flat: `index.html`, `styles.css`, `app.js`, and the other files all sit together. This avoids having to create an `assets` folder manually.

If GitHub Pages is not already enabled, open **Settings > Pages**, choose **Deploy from a branch**, select `main` and `/ (root)`, then save.

## Important release files

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
- `supabase/migrations/20260809105855_fix_shared_waiter_extension_schema.sql` — small repair for databases that installed the first Release 1A.1 file
- `supabase/migrations/20260809195328_restrict_waiter_fulfilled_order_history.sql` — waiter-specific served and rejected order-history privacy
- `supabase/migrations/20260809200244_fix_waiter_order_history_login_link.sql` — repair that links the active waiter login to history without blocking the Orders page
- `supabase/migrations/20260809201204_auto_accept_and_route_orders.sql` — automatic order acceptance and direct Kitchen/Bar routing
- `business.html` and `assets/business.js` — Release 1B business, currency, payment-method, business-day, and security controls
- `supabase/migrations/20260811085036_release_1b_business_payment_foundations.sql` — Release 1B branch, business date, payment, permission, audit, RLS, and monitoring foundation

## Release 2 files

- `floor.html` and `assets/floor.js` — live floor, layout editing, waiter sections, and table transfers
- `analytics.html` and `assets/analytics.js` — table, waiter, station, KDS, and service-request analytics
- `assets/stations.js` — acknowledged KDS tickets, timers, priority, ready alerts, and sold-out actions
- `supabase/migrations/20260812110000_release_2_floor_service_advanced_kds.sql` — Release 2 database, secure functions, RLS, grants, and Realtime setup

## Release 3 files

- `operations.html` and `assets/operations.js` — staff shifts, attendance, tasks, logbook, cash shifts, reconciliation, and day close
- `approvals.html` and `assets/approvals.js` — controlled requests, manager decisions, and approval thresholds
- `billing.html` and `assets/billing.js` — equal-share and item-assigned split bills and offline guest-bill payments
- `reports.html` and `assets/reports.js` — financial, menu, table, waiter, cash, void, discount, and attendance reports with CSV export
- `supabase/migrations/20260813110000_release_3_financial_staff_operations.sql` — Release 3 schema, secure functions, RLS policies, grants, audit records, and Realtime setup

## Security note

The Supabase anon key in `assets/config.js` is designed to be public. TafuraFlow security is enforced by Row Level Security and the secure SQL functions. Never place a Supabase service-role key in an HTML or JavaScript file.
