// Bundles the web app into one self-contained file, dist/Aria.html: open it straight from
// disk (double-click) or upload it to any static host. No dependencies.
//   node web/build.mjs [supabaseUrl anonKey]   — optionally bakes in the backend settings
import { readFile, writeFile, mkdir } from "node:fs/promises";

const root = new URL("./", import.meta.url);
const read = (path) => readFile(new URL(path, root), "utf8");
const ORDER = ["dates", "tools", "planner", "executor", "assistant", "openrouter", "supabase", "markdown", "app"];

// Each module becomes a function scope that returns its exports; imports become destructuring.
const modules = [];
for (const name of ORDER) {
  let source = await read(`js/${name}.js`);
  const exported = [];
  source = source.replace(/^import\s*\{([^}]*)\}\s*from\s*"\.\/(\w+)\.js";\s*$/gm, (_, names, from) =>
    `const {${names.replace(/\s+/g, " ").trim()}} = __${from};`);
  source = source.replace(/^export\s+(async\s+function|function|const|let|class)\s+(\w+)/gm, (_, kind, id) => {
    exported.push(id);
    return `${kind} ${id}`;
  });
  source = source.replace(/^export\s*\{([^}]*)\};?\s*$/gm, (_, names) => {
    exported.push(...names.split(",").map((n) => n.trim()).filter(Boolean));
    return "";
  });
  if (/^\s*(import|export)\b/m.test(source)) throw new Error(`${name}.js has an import/export the bundler doesn't understand`);
  modules.push(`const __${name} = (() => {\n${source}\nreturn { ${exported.join(", ")} };\n})();`);
}

const [url, key] = process.argv.slice(2);
const config = url && key ? `window.ARIA_CONFIG = ${JSON.stringify({ supabaseUrl: url, supabaseAnonKey: key })};` : (await read("config.js"));
const icon = `data:image/svg+xml;base64,${Buffer.from(await read("icon.svg")).toString("base64")}`;
const css = await read("styles.css");
const script = modules.join("\n\n").replaceAll("</script", "<\\/script").replaceAll('src="icon.svg"', `src="${icon}"`);
const html = (await read("index.html"))
  .replace('<link rel="stylesheet" href="styles.css">', () => `<style>\n${css}</style>`)
  .replace(/<link rel="manifest"[^>]*>\n\s*/, "")
  .replace(/<script src="config\.js"[^>]*><\/script>/, () => `<script>${config}</script>`)
  .replace('<script type="module" src="js/app.js"></script>', () => `<script type="module">\n${script}\n</script>`)
  .replaceAll('href="icon.svg"', `href="${icon}"`);
if (html.includes("icon.svg")) throw new Error("an icon reference was not inlined");
await mkdir(new URL("dist/", root), { recursive: true });
await writeFile(new URL("dist/Aria.html", root), html);
console.log(`dist/Aria.html (${(html.length / 1024).toFixed(0)} KB)${url ? ` for ${url}` : ""}`);
