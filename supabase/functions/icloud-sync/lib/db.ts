// PostgREST with the service role (the function acts for each account; every query filters
// by user_id explicitly).

export class Db {
  private url: string;
  private key: string;
  private fetchImpl: typeof fetch;

  constructor(supabaseUrl: string, serviceKey: string, fetchImpl: typeof fetch = fetch) {
    this.url = supabaseUrl.replace(/\/$/, "");
    this.key = serviceKey;
    this.fetchImpl = fetchImpl;
  }

  private headers(extra: Record<string, string> = {}): Record<string, string> {
    const h: Record<string, string> = { apikey: this.key, "Content-Type": "application/json", ...extra };
    // Legacy service keys are JWTs; new sb_secret_ keys go in apikey only.
    if (this.key.startsWith("eyJ")) h.Authorization = `Bearer ${this.key}`;
    return h;
  }

  async request<T>(method: string, path: string, params: Record<string, string> = {}, body?: unknown, prefer?: string): Promise<T> {
    const query = new URLSearchParams(params).toString();
    const response = await this.fetchImpl(`${this.url}/rest/v1/${path}${query ? `?${query}` : ""}`, {
      method, headers: this.headers(prefer ? { Prefer: prefer } : {}), body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await response.text();
    if (!response.ok) throw new Error(`Database ${method} ${path} failed (${response.status}): ${text.slice(0, 300)}`);
    return (text ? JSON.parse(text) : null) as T;
  }

  select<T>(table: string, params: Record<string, string>): Promise<T[]> {
    return this.request<T[]>("GET", table, params);
  }

  insert<T>(table: string, rows: unknown, params: Record<string, string> = {}, prefer = "return=representation"): Promise<T[]> {
    return this.request<T[]>("POST", table, params, rows, prefer);
  }

  update<T>(table: string, filters: Record<string, string>, body: unknown): Promise<T[]> {
    return this.request<T[]>("PATCH", table, filters, body, "return=representation");
  }

  async remove(table: string, filters: Record<string, string>): Promise<void> {
    await this.request("DELETE", table, filters, undefined, "return=minimal");
  }

  rpc<T>(name: string, args: Record<string, unknown>): Promise<T> {
    return this.request<T>("POST", `rpc/${name}`, {}, args);
  }

  /** The signed-in user behind an access token, or null. */
  async userFor(authorization: string | null): Promise<{ id: string; email?: string } | null> {
    if (!authorization?.startsWith("Bearer ")) return null;
    const response = await this.fetchImpl(`${this.url}/auth/v1/user`, { headers: { apikey: this.key, Authorization: authorization } });
    if (!response.ok) return null;
    const user = await response.json();
    return user?.id ? user : null;
  }
}

/** `in.(a,b,c)` filters, in chunks so URLs stay short. */
export function chunks<T>(items: T[], size = 80): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
}
