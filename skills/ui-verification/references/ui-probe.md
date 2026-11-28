# UI probe template

Set the constants, save the script outside the checkout and run
`ego-browser nodejs < /absolute/path/probe.mjs`. It checks, per viewport and scheme:
horizontal overflow, interactive targets under 24x24 CSS px, `img` without `alt`,
inputs without a label, `aria-label` or `aria-labelledby`, console errors and
exceptions, plus a clipped screenshot. Contrast is not checked.

```js
const URL = "http://localhost:3000/";
const ALLOWED_ORIGINS = ["http://localhost:3000"];
const READY_SELECTOR = "h1";
const OUT_DIR = "/absolute/path/to/checkout/.scratch/<feature>/ui";
const SPACE = "<feature>-<task>";
const VIEWPORTS = [
  { w: 375, h: 812 },
  { w: 768, h: 1024 },
  { w: 1440, h: 900 },
];
const SCHEMES = ["light", "dark"];

const assertAllowed = (href) => {
  const target = new globalThis.URL(href);
  if (target.protocol !== "file:" && !ALLOWED_ORIGINS.includes(target.origin)) {
    throw new Error(`origin not allowed: ${target.origin}`);
  }
};
assertAllowed(URL);

const fs = await import("node:fs/promises");
await fs.mkdir(OUT_DIR, { recursive: true });

const task = await taskSpace(SPACE);
const page = task.page("p1");
await page.cdp("egoAutomated.disable");
await page.cdp("Runtime.enable");

const audit = () => {
  const vw = document.documentElement.clientWidth;
  const sel = "button,a[href],input,select,textarea,[role=button]";
  return {
    overflow: [...document.querySelectorAll("body *")]
      .filter((n) => n.getBoundingClientRect().right > vw + 1)
      .map((n) => n.tagName + "." + n.className),
    scrollWidth: document.documentElement.scrollWidth,
    clientWidth: vw,
    smallTargets: [...document.querySelectorAll(sel)]
      .filter((n) => {
        const r = n.getBoundingClientRect();
        return r.width < 24 || r.height < 24;
      })
      .map((n) => n.outerHTML.slice(0, 60)),
    imgNoAlt: [...document.images].filter((i) => !i.hasAttribute("alt")).length,
    unlabeled: [...document.querySelectorAll("input")]
      .filter((i) => !i.labels?.length && !i.getAttribute("aria-label") && !i.getAttribute("aria-labelledby"))
      .map((i) => i.outerHTML.slice(0, 60)),
  };
};

const summary = [];
for (const { w, h } of VIEWPORTS) {
  for (const scheme of SCHEMES) {
    await page.cdp("Emulation.setDeviceMetricsOverride", { width: w, height: h, deviceScaleFactor: 1, mobile: false });
    await page.cdp("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: scheme }] });
    await page.goto(URL);
    assertAllowed(await page.url());
    await page.waitForSelector(READY_SELECTOR);
    const found = await page.evaluate(audit);
    const shot = await page.screenshot({
      path: `${OUT_DIR}/${w}x${h}-${scheme}.png`,
      clip: { x: 0, y: 0, width: w, height: h, scale: 1 },
    });
    const events = await page.events();
    const consoleErrors = events
      .filter((e) => e.method === "Runtime.consoleAPICalled" && e.params?.type === "error")
      .map((e) => e.params.args?.map((a) => a.value ?? a.description));
    const exceptions = events
      .filter((e) => e.method === "Runtime.exceptionThrown")
      .map((e) => e.params?.exceptionDetails?.exception?.description ?? e.params?.exceptionDetails?.text);
    summary.push({ viewport: `${w}x${h}`, scheme, shot, ...found, consoleErrors, exceptions });
  }
}

await page.cdp("Emulation.clearDeviceMetricsOverride");
await page.cdp("Emulation.setEmulatedMedia", { features: [] });
await fs.writeFile(`${OUT_DIR}/summary.json`, JSON.stringify(summary, null, 2));
console.log(JSON.stringify(summary, null, 2));
console.log({ taskSpaceId: task.spaceId });
console.log(await page.snapshot({ includeStableLocator: true }));
```

Run the cleanup as a separate, last script, with the `taskSpaceId` printed above:

```js
const task = await taskSpace(7);
console.log(await task.finish({ keep: [] }));
```
