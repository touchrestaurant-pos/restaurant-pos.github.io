# restaurant-pos

Restaurant POS: cashier, kitchen queue, stock with GRV, recipes, admin and supervisor.
One Flutter app for Android, iOS, Windows, Mac and web. Works offline and syncs with Supabase.

## Roles

| Role | Can do |
| --- | --- |
| Cashier | Take orders, take payment (cash and manual credit card) |
| Kitchen | See the order queue, special requests, mark items done and orders ready |
| Stock | Stock master, receive stock (GRV), adjustments |
| Supervisor | Cashier screens plus voids, refunds, cash-up, approve adjustments |
| Admin | Everything, plus menu, recipes, staff and company settings (name, details, logo) |

## Build without installing anything

GitHub builds the apps for you (`.github/workflows/build.yml`). Open the repo's **Actions**
tab, click the latest "Build apps" run, and download from **Artifacts**:
`restaurant-pos-web`, `restaurant-pos-android-apk`, `restaurant-pos-windows`.
Press **Run workflow** to build again at any time.

## Building on your own computer (optional)

1. Install Flutter: https://docs.flutter.dev/get-started/install
2. In this folder run, once, to create the Android / iOS / web / desktop folders:

   ```
   flutter create --project-name restaurant_pos --org com.restaurantpos .
   ```

   If it replaces `lib/main.dart` or `pubspec.yaml`, run `git checkout lib/main.dart pubspec.yaml`.
3. `flutter pub get`
4. Create the first admin user in Supabase: Dashboard, Authentication, Users, Add user,
   tick "Auto Confirm User". The first user created becomes **admin**. Everyone after
   starts as cashier and the admin changes their role.
5. Run it: `flutter run -d chrome` (or `-d windows`, `-d macos`, or pick a phone).

## Database

`supabase/migrations/` holds the full database: tables, stock logic, security rules and sample data.
Already applied to the `restaurant-pos` Supabase project.

- Selling an item deducts its recipe ingredients from stock.
- Posting a GRV adds stock and updates the average cost.
- Voiding an order puts the stock back.

## Security notes

- The app only contains the Supabase URL and publishable key. What each person can see or
  change is enforced by the row level security rules in the database.
- Never put the service-role key or the database password in the app or in this repo.
- After creating your admin, turn off "Allow new users to sign up" in
  Supabase, Authentication, Sign In / Providers, so only the admin adds staff.

## Offline

Menu, stock and recent orders are saved on the device. Orders, payments and GRVs made
offline wait in an outbox and upload when the connection returns. Each device creates its
own ids and order references, so tills never clash. The first sign-in on a device needs internet.
