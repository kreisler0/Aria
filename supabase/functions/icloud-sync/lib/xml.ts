// A small, tolerant XML reader for WebDAV/CalDAV responses. Element names keep only their
// local part (namespace prefixes are dropped), which is all CalDAV needs.

export interface XmlNode {
  name: string;
  attrs: Record<string, string>;
  children: XmlNode[];
  text: string;
}

const ENTITIES: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'" };

export function decodeEntities(text: string): string {
  return text.replace(/&(#x[0-9a-f]+|#\d+|\w+);/gi, (whole, code: string) => {
    if (code[0] === "#") {
      const n = code[1] === "x" || code[1] === "X" ? parseInt(code.slice(2), 16) : parseInt(code.slice(1), 10);
      return Number.isFinite(n) ? String.fromCodePoint(n) : whole;
    }
    return ENTITIES[code] ?? whole;
  });
}

const localName = (qname: string) => qname.slice(qname.indexOf(":") + 1);

export function parseXml(source: string): XmlNode {
  const root: XmlNode = { name: "#document", attrs: {}, children: [], text: "" };
  const stack: XmlNode[] = [root];
  const pattern = /<!\[CDATA\[([\s\S]*?)\]\]>|<!--[\s\S]*?-->|<\?[\s\S]*?\?>|<!DOCTYPE[^>]*>|<\/\s*([^\s>]+)\s*>|<\s*([^\s/>]+)((?:\s+[^\s=]+\s*=\s*(?:"[^"]*"|'[^']*'))*)\s*(\/?)>|([^<]+)/g;
  for (const match of source.matchAll(pattern)) {
    const [, cdata, closing, opening, rawAttrs, selfClosing, text] = match;
    const top = stack[stack.length - 1];
    if (cdata !== undefined) {
      top.text += cdata;
    } else if (closing !== undefined) {
      const name = localName(closing);
      // Pop to the matching element, tolerating stray tags.
      for (let i = stack.length - 1; i > 0; i--) {
        if (stack[i].name === name) {
          stack.length = i;
          break;
        }
      }
    } else if (opening !== undefined) {
      const attrs: Record<string, string> = {};
      for (const a of (rawAttrs ?? "").matchAll(/([^\s=]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g)) {
        attrs[localName(a[1])] = decodeEntities(a[2] ?? a[3] ?? "");
      }
      const node: XmlNode = { name: localName(opening), attrs, children: [], text: "" };
      top.children.push(node);
      if (!selfClosing) stack.push(node);
    } else if (text !== undefined) {
      top.text += decodeEntities(text);
    }
  }
  return root;
}

/** All descendants (depth-first) with this local name. */
export function findAll(node: XmlNode, name: string): XmlNode[] {
  const out: XmlNode[] = [];
  const walk = (n: XmlNode) => {
    for (const child of n.children) {
      if (child.name === name) out.push(child);
      walk(child);
    }
  };
  walk(node);
  return out;
}

export function find(node: XmlNode, name: string): XmlNode | undefined {
  return findAll(node, name)[0];
}

/** Text of the first descendant with this name (trimmed), or undefined. */
export function textOf(node: XmlNode, name: string): string | undefined {
  const found = find(node, name);
  return found ? found.text.trim() : undefined;
}

/** A multistatus response as [{href, props (only those with a 2xx status)}]. */
export interface DavResponse {
  href: string;
  props: XmlNode;
}

export function multistatus(xml: string): DavResponse[] {
  const doc = parseXml(xml);
  return findAll(doc, "response").map((response) => {
    const href = textOf(response, "href") ?? "";
    const props: XmlNode = { name: "prop", attrs: {}, children: [], text: "" };
    for (const propstat of findAll(response, "propstat")) {
      const status = textOf(propstat, "status") ?? "HTTP/1.1 200 OK";
      if (!/\s2\d\d\s/.test(` ${status} `)) continue;
      const prop = find(propstat, "prop");
      if (prop) props.children.push(...prop.children);
    }
    return { href, props };
  });
}
