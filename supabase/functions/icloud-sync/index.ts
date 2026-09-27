// Supabase Edge Function entry point: iCloud Calendar sync for Aria.
// Deployed by .github/workflows/supabase-deploy.yml with verify_jwt off (pg_cron calls it
// without a user); every user action checks the caller's token itself.
import { createHandler } from "./lib/handler.ts";

const env = {
  supabaseUrl: Deno.env.get("SUPABASE_URL") ?? "",
  serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  encryptionKey: Deno.env.get("ARIA_ENCRYPTION_KEY") ?? "",
};
if (!env.encryptionKey) console.error("ARIA_ENCRYPTION_KEY is not set: connecting iCloud will fail.");

const handle = createHandler(env);
Deno.serve((request) =>
  env.encryptionKey
    ? handle(request)
    : new Response(JSON.stringify({ error: "The calendar service isn't fully set up (missing ARIA_ENCRYPTION_KEY)." }), {
      status: 503, headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" },
    }));
