// A small in-memory CalDAV server that answers like iCloud, for tests.
import { createServer, type Server } from "node:http";

export const APPLE_ID = "ada@icloud.com";
export const APP_PASSWORD = "abcd-efgh-ijkl-mnop";

interface Item { etag: string; ics: string }
interface Cal { name: string; readOnly: boolean; kind: "VEVENT" | "VTODO"; items: Map<string, Item> }

export class FakeICloud {
  server!: Server;
  base = "";
  calendars = new Map<string, Cal>(); // path -> calendar
  requests: string[] = [];
  private n = 0;

  async start(): Promise<void> {
    this.server = createServer((req, res) => {
      let body = "";
      req.on("data", (c) => (body += c));
      req.on("end", () => this.handle(req.method!, req.url!, req.headers as Record<string, string>, body, res));
    });
    await new Promise<void>((r) => this.server.listen(0, "127.0.0.1", r));
    const { port } = this.server.address() as { port: number };
    this.base = `http://127.0.0.1:${port}`;
  }

  stop() {
    this.server.close();
  }

  addCalendar(path: string, name: string, readOnly = false, kind: "VEVENT" | "VTODO" = "VEVENT") {
    this.calendars.set(path, { name, readOnly, kind, items: new Map() });
  }

  put(calPath: string, name: string, ics: string) {
    this.calendars.get(calPath)!.items.set(name, { etag: `"e${++this.n}"`, ics });
  }

  item(calPath: string, name: string) {
    return this.calendars.get(calPath)!.items.get(name);
  }

  private handle(method: string, url: string, headers: Record<string, string>, body: string, res: import("node:http").ServerResponse) {
    this.requests.push(`${method} ${url}`);
    const expected = "Basic " + Buffer.from(`${APPLE_ID}:${APP_PASSWORD}`).toString("base64");
    if (headers.authorization !== expected) {
      res.writeHead(401, { "WWW-Authenticate": 'Basic realm="iCloud"' });
      return res.end();
    }
    const path = new URL(url, this.base).pathname;
    const ms = (inner: string) => {
      res.writeHead(207, { "Content-Type": "application/xml; charset=utf-8" });
      res.end(`<?xml version="1.0" encoding="UTF-8"?><multistatus xmlns="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav" xmlns:A="http://apple.com/ns/ical/">${inner}</multistatus>`);
    };
    const ok = (href: string, props: string) => `<response><href>${href}</href><propstat><prop>${props}</prop><status>HTTP/1.1 200 OK</status></propstat></response>`;
    if (method === "PROPFIND" && path === "/") return ms(ok("/", "<current-user-principal><href>/1234/principal/</href></current-user-principal>"));
    if (method === "PROPFIND" && path === "/1234/principal/") {
      // iCloud hands out an absolute URL on another host (p##-caldav); here, the same server.
      return ms(ok("/1234/principal/", `<C:calendar-home-set><href>${this.base}/1234/calendars/</href></C:calendar-home-set>`));
    }
    if (method === "PROPFIND" && path === "/1234/calendars/") {
      let inner = ok("/1234/calendars/", "<resourcetype><collection/></resourcetype>");
      inner += ok("/1234/calendars/inbox/", "<resourcetype><collection/><C:schedule-inbox/></resourcetype>");
      for (const [p, c] of this.calendars) {
        const privileges = c.readOnly ? "<privilege><read/></privilege>" : "<privilege><read/></privilege><privilege><write/></privilege>";
        inner += ok(p, `<displayname>${c.name}</displayname><resourcetype><collection/><C:calendar/></resourcetype>` +
          `<C:supported-calendar-component-set><C:comp name="${c.kind}"/></C:supported-calendar-component-set>` +
          `<A:calendar-color>#FF2968FF</A:calendar-color><current-user-privilege-set>${privileges}</current-user-privilege-set>`);
      }
      return ms(inner);
    }
    const calPath = [...this.calendars.keys()].find((p) => path.startsWith(p));
    const cal = calPath ? this.calendars.get(calPath)! : undefined;
    if (method === "REPORT" && cal && path === calPath) {
      return ms([...cal.items].map(([name, it]) => ok(`${calPath}${name}`,
        `<getetag>${it.etag}</getetag><C:calendar-data><![CDATA[${it.ics}]]></C:calendar-data>`)).join(""));
    }
    const name = calPath ? path.slice(calPath.length) : "";
    const existing = cal?.items.get(name);
    if (method === "GET") {
      if (!existing) { res.writeHead(404); return res.end(); }
      res.writeHead(200, { ETag: existing.etag, "Content-Type": "text/calendar" });
      return res.end(existing.ics);
    }
    if (method === "PUT" && cal) {
      if (cal.readOnly) { res.writeHead(403); return res.end(); }
      if (headers["if-none-match"] === "*" && existing) { res.writeHead(412); return res.end(); }
      if (headers["if-match"] && headers["if-match"] !== existing?.etag) { res.writeHead(412); return res.end(); }
      const etag = `"e${++this.n}"`;
      cal.items.set(name, { etag, ics: body });
      res.writeHead(existing ? 204 : 201, { ETag: etag });
      return res.end();
    }
    if (method === "DELETE" && cal) {
      if (!existing) { res.writeHead(404); return res.end(); }
      if (headers["if-match"] && headers["if-match"] !== existing.etag) { res.writeHead(412); return res.end(); }
      cal.items.delete(name);
      res.writeHead(204);
      return res.end();
    }
    res.writeHead(405);
    res.end();
  }
}
