# NexaFlow CRM

## What this app is

NexaFlow is a business-management app for field-service companies (think
plumbers, cleaners, contractors, and similar businesses that send workers
out to jobs). It's a **multi-tenant** app, meaning many different
businesses use the same app and database, each seeing only their own data.

It covers most of what a service business needs day to day:
- Contacts, jobs, quotes, and invoices
- Scheduling: appointments, routes, and a booking page customers can use
- Employees: timesheets, clock in/out, PTO requests and approvals
- Marketing: email/SMS campaigns, automations, reviews, referrals
- Payments: Stripe for invoices and payouts
- Integrations: QuickBooks, Gmail, Microsoft/Outlook, Twilio (calls/SMS)
- An AI chat assistant and AI-assisted form/document handling
- A "superuser" mode that lets NexaFlow staff impersonate a business to
  help with support

## Tech stack

- **Flutter** — the app itself (works as a web app and can build for
  mobile/desktop too). Written in Dart.
- **Supabase** — the backend: a Postgres database, user login
  (Authentication), and serverless backend code ("Edge Functions").
- **Firebase Hosting** — serves the built web version of the app.
- **Stripe, Twilio, QuickBooks, Gmail/Microsoft Graph** — outside services
  the app talks to for payments, texting/calling, accounting sync, and
  email.

## Main folders

- `lib/` — the Flutter app (this is what users see and interact with).
  - `lib/screens/` — one file per screen (Jobs, Invoices, Timesheets,
    Employees, Contacts, Settings, etc.). This is where most of the UI
    lives.
  - `lib/widgets/` — smaller reusable pieces used across multiple screens
    (dialogs, layout shell, form fillers, etc.).
  - `lib/navigation/app_router.dart` — defines every URL/route in the app
    and which screen it shows.
  - `lib/utils/` — small helper functions, including
    `business_utils.dart`, which figures out which business the current
    user belongs to (see the multi-tenant rule below).
  - `lib/config/` — app configuration such as the Supabase connection
    keys.
  - `lib/theme/` — shared colors, fonts, and styling.
- `supabase/` — the backend.
  - `supabase/functions/` — the Edge Functions (see below).
  - `supabase/migrations/` — SQL files that create/change database tables
    over time, in order.
  - `supabase/config.toml` — settings for each Edge Function (whether
    it's enabled, whether it requires a logged-in user, etc.).

## How the Supabase Edge Functions are organized

Edge Functions live under `supabase/functions/`, one folder per function,
each with its own `index.ts`. There are over 100 of them. Each one is a
small, focused backend task rather than one big backend program. They
group into rough categories:

- **Communication**: `send-email`, `send-sms`, `bulk-email`, `bulk-sms`,
  `receive-email`, `receive-sms`, `gmail-*`, `microsoft-*`
- **Jobs & forms**: `get-job-form-data`, `extract-job-form-ai`,
  `generate-job-form-pdf`, `submit-job-form-action`, `job-form-editor`
- **Billing & payments**: `create-invoice-payment`, `send-invoice`,
  `stripe-webhook`, `stripe-connect-webhook`, `generate-payment-link`
- **Employees & time**: `clock-in-out`, `submit-timesheet`,
  `decide-timesheet`, `check-overtime-thresholds`, `notify-pto-request`
- **Campaigns & automation**: `dispatch-campaign-email`,
  `dispatch-campaign-sms`, `run-automation`,
  `process-scheduled-automations`
- **Integrations**: `quickbooks-*`, `gmail-*`, `microsoft-*`
- **Reporting**: `get-job-costing-report`, `get-tax-summary-report`,
  `get-expense-report`, `get-checklists-report`
- **Client-facing/public**: `submit-booking`, `get-available-slots`,
  `client-portal-action`, `handle-referral-signup`

Most functions follow the same pattern: check that the request has a
valid logged-in user, look up that user's `business_id`, and then only
read or write rows that belong to that `business_id`.

Which functions are active and how they're configured (e.g., whether they
require a logged-in user) is listed in `supabase/config.toml`.

---

## Working rules for changes in this project

1. **Explain things in plain language, one step at a time.** I'm not a
   developer, so avoid jargon where possible, and don't dump a wall of
   technical detail — walk me through what's happening step by step.
2. **Make changes directly in the files**, then afterward tell me in
   plain language what was changed and why.
3. **This is a multi-tenant app** — every database query must filter by
   `business_id` so one business never sees another business's data.
4. **Ask before running any command that installs, deletes, or deploys
   anything** (e.g., installing packages, deleting files/branches,
   deploying Edge Functions, or pushing schema changes to the live
   database).
