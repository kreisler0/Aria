// Regenerates icon.svg, apple-touch-icon.png and icon-512.png from js/logo.js.
//   node web/tools/icons.mjs   (needs Playwright's Chromium for the PNGs)
import { writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { logoSvg } from "../js/logo.js";

const dir = new URL("../", import.meta.url);
const titled = (svg) => svg.replace(/^<svg([^>]*)>/, "<svg$1><title>Aria</title>");
await writeFile(new URL("icon.svg", dir), `${titled(logoSvg())}\n`);

const { chromium } = await import("playwright").catch(() => createRequire(`${process.execPath}/../../lib/node_modules/`)("playwright"));
const browser = await chromium.launch();
for (const [file, size] of [["apple-touch-icon.png", 180], ["icon-512.png", 512]]) {
  const page = await browser.newPage({ viewport: { width: size, height: size } });
  await page.setContent(`<body style="margin:0">${logoSvg({ square: true, attrs: ` width="${size}" height="${size}"` })}</body>`);
  await page.screenshot({ path: new URL(file, dir).pathname });
  await page.close();
}
await browser.close();
console.log("icon.svg, apple-touch-icon.png and icon-512.png written");
