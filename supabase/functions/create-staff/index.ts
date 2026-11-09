// Staff administration for ADMINS, run on Supabase's servers where the
// service-role key is available (so that key never has to be inside the app).
//
// action "create": add a staff login with a username and password
// action "reset":  set a new password for a staff member (forgotten password)
import { createClient } from "jsr:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });

const ROLES = ["cashier", "kitchen", "stock", "supervisor", "admin"];
// Must match staffLoginDomain in lib/config.dart
const DOMAIN = Deno.env.get("STAFF_LOGIN_DOMAIN") ?? "touchrestaurant-pos.github.io";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
    const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    const caller = createClient(url, anon, {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: { user } } = await caller.auth.getUser();
    if (!user) return json({ error: "Not signed in" }, 401);

    const admin = createClient(url, service);
    const { data: me } = await admin
      .from("staff_profiles")
      .select("role, active")
      .eq("id", user.id)
      .maybeSingle();
    if (!me || me.role !== "admin" || !me.active) {
      return json({ error: "Only an admin can do this" }, 403);
    }

    const body = await req.json();
    const action = String(body.action ?? "create");
    const password = String(body.password ?? "");
    if (password.length < 6) return json({ error: "Password must be at least 6 characters" }, 400);

    if (action === "reset") {
      const userId = String(body.user_id ?? "");
      const { data: target } = await admin
        .from("staff_profiles")
        .select("id")
        .eq("id", userId)
        .maybeSingle();
      if (!target) return json({ error: "Staff member not found" }, 404);
      const { error } = await admin.auth.admin.updateUserById(userId, { password });
      if (error) return json({ error: error.message }, 400);
      return json({ ok: true });
    }

    if (action !== "create") return json({ error: "Unknown action" }, 400);

    const fullName = String(body.full_name ?? "").trim();
    const username = String(body.username ?? "").trim().toLowerCase();
    const role = String(body.role ?? "cashier");

    if (!fullName) return json({ error: "Enter the staff member's name" }, 400);
    if (!/^[a-z0-9._-]{3,30}$/.test(username)) {
      return json({ error: "Username must be 3 to 30 letters, numbers, dots, dashes or underscores" }, 400);
    }
    if (!ROLES.includes(role)) return json({ error: "Unknown role" }, 400);

    const { data: taken } = await admin
      .from("staff_profiles")
      .select("id")
      .ilike("username", username)
      .maybeSingle();
    if (taken) return json({ error: "That username is already taken" }, 400);

    const { data, error } = await admin.auth.admin.createUser({
      email: `${username}@${DOMAIN}`,
      password,
      email_confirm: true,
      user_metadata: { full_name: fullName, username },
    });
    if (error) return json({ error: error.message }, 400);

    // A database trigger creates the profile as "cashier"; set the chosen role.
    const { error: profileError } = await admin
      .from("staff_profiles")
      .update({ role, full_name: fullName, username })
      .eq("id", data.user.id);
    if (profileError) return json({ error: profileError.message }, 500);

    return json({ ok: true, id: data.user.id });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
