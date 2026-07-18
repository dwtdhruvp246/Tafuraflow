# DineQR

DineQR is a restaurant ordering platform built around secure, single-session table QR codes.

## Included in this first version

- Super Admin company and owner setup
- Owner, waiter, kitchen, cashier, and customer views
- Restaurant branding across every portal
- Staff-opened table sessions with unique QR codes
- Waiter-approved customer orders
- Kitchen order handling
- Waiter and bill requests
- Offline payment recording and printable receipts
- Owner-controlled tax and service charges
- Supabase schema with restaurant isolation and role-based security policies

## Run locally

1. Install Node.js 22.13 or later.
2. Run `npm install`.
3. Copy `.env.example` to `.env.local` and add the Supabase project values.
4. Run `npm run dev`.

Use `npm test` to build and run the product-flow checks.

## Publish with GitHub Pages

1. Upload the complete project to a GitHub repository using the `main` branch.
2. Open the repository's **Settings → Pages**.
3. Under **Build and deployment**, select **GitHub Actions** as the source.
4. Push to `main`, or run **Deploy DineQR to GitHub Pages** from the Actions tab.

The included workflow builds the project and publishes the generated `out/index.html` automatically. It also handles both repository URLs (`username.github.io/repository`) and account URLs (`username.github.io`).

## Database

Apply `supabase/migrations/20260718120000_initial_schema.sql` to the Supabase project. Public customer operations are intentionally expected to use protected server-side functions that validate an active table-session token.
