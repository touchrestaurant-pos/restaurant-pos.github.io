// Lets a signed-in ADMIN add a staff login from inside the app.
// Runs on Supabase's servers, where the service-role key is available, so that
// key never has to be inside the app.
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
      return json({ error: "Only an admin can add staff" }, 403);
    }

    const body = await req.json();
    const fullName = String(body.full_name ?? "").trim();
    const email = String(body.email ?? "").trim().toLowerCase();
    const password = String(body.password ?? "");
    const role = String(body.role ?? "cashier");

    if (!fullName) return json({ error: "Enter the staff member's name" }, 400);
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return json({ error: "Enter a valid email" }, 400);
    if (password.length < 6) return json({ error: "Password must be at least 6 characters" }, 400);
    if (!ROLES.includes(role)) return json({ error: "Unknown role" }, 400);

    const { data, error } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { full_name: fullName },
    });
    if (error) return json({ error: error.message }, 400);

    // A database trigger creates the profile as "cashier"; set the chosen role.
    const { error: profileError } = await admin
      .from("staff_profiles")
      .update({ role, full_name: fullName })
      .eq("id", data.user.id);
    if (profileError) return json({ error: profileError.message }, 500);

    return json({ ok: true, id: data.user.id });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
