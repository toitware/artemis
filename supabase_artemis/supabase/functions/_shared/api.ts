import { createClient } from "@supabase/supabase-js";
import type { SupabaseClient } from "@supabase/supabase-js";

export function client(req: Request, schema = "toit_artemis"): SupabaseClient {
  const authorization = req.headers.get("Authorization") ??
    `Bearer ${Deno.env.get("SUPABASE_ANON_KEY")}`;
  return createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_ANON_KEY") ?? "",
    {
      auth: { persistSession: false },
      global: { headers: { Authorization: authorization } },
      db: { schema: schema as "public" },
    },
  );
}

export function route(req: Request, functionName: string): string {
  const pathname = new URL(req.url).pathname;
  const marker = `/${functionName}`;
  const start = pathname.indexOf(marker);
  if (start < 0) throw new Error(`Invalid ${functionName} URL`);
  return pathname.slice(start + marker.length) || "/";
}

export function rpcParameters(body: Record<string, unknown>) {
  return Object.fromEntries(
    Object.entries(body).map(([key, value]) => [`_${key}`, value]),
  );
}

export async function rpc(
  supabase: SupabaseClient,
  name: string,
  parameters: Record<string, unknown>,
  retry = false,
) {
  const attempts = retry ? 3 : 1;
  for (let attempt = 0; attempt < attempts; attempt++) {
    const { data, error } = await supabase.rpc(name, parameters);
    if (!error) return data ?? null;
    const status = (error as unknown as { status?: number }).status;
    if (status !== 502 || attempt === attempts - 1) {
      throw new Error(error.message);
    }
    await new Promise((resolve) => setTimeout(resolve, 200 * (attempt + 1)));
  }
}

export function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data ?? null), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

export function serve(handler: (req: Request) => Promise<Response | unknown>) {
  Deno.serve(async (req: Request) => {
    try {
      const result = await handler(req);
      return result instanceof Response ? result : json(result);
    } catch (error) {
      console.error(error);
      const message = error instanceof Error ? error.message : String(error);
      return json({ message }, 500);
    }
  });
}

export function requireMethod(req: Request, method: string) {
  if (req.method !== method) {
    throw new Error(`Method ${req.method} is not allowed`);
  }
}

export function parameter(url: URL, name: string): string {
  const value = url.searchParams.get(name);
  if (value === null) throw new Error(`Missing query parameter: ${name}`);
  return value;
}
