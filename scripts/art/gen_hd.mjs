#!/usr/bin/env node
// HD board-art batch for the CTF dungeon-crawler replay. Regenerates the
// data/hd/*.png masters that src/ctf/hd.nim rasterizes, art-directed from the
// dungeon-crawler reference family (Game Art Partners "The Dungeon", CraftPix
// top-down packs, Dungeon Crawl Stone Soup): COOL grey-blue carved stone as the
// dominant structure, WARM torch/ember as localized punctuation, RED/BLUE the
// only saturated channel.
//
// ONE locked STYLE suffix carries coherence across the batch (L46 — the style
// STRING, not a shared seed which over-locks identity). Two suffixes: STYLE for
// isolated objects on a dark plate, SEAMLESS for the two full-bleed tile
// textures.
//
// Engine contracts honored (do NOT let the model violate these):
//  • crew_red.png — recoloredCrew() (hd.nim:418) tints ONLY red-dominant pixels
//    toward the team color; everything else is drawn literally. So the team
//    identity MUST be RED CLOTH (tabard/cloak) and the armor/hood MUST stay
//    NEUTRAL GREY. And NO baked weapon — the game's aim-dots are the only gun
//    (gen_crew.py lesson: a baked weapon reads as a phantom second gun that
//    disagrees with the 360° aim indicator). Strict top-down, radially
//    symmetric footprint, one clear "front" so 16 rotations read.
//  • heart_red/blue + pedestal_red/blue — PAIRED seeds (same seed, prompt differs
//    only in the color word) so red and blue share geometry and diverge only in
//    tint/glow.
//
// Usage: node scripts/art/gen_hd.mjs [only=key,key]
import { spawn } from "node:child_process";
import { readFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";

const OUT = path.join(process.cwd(), "art/gen");
mkdirSync(OUT, { recursive: true });
const settings = JSON.parse(readFileSync(path.join(homedir(), ".gemini/settings.json"), "utf8"));
const key = process.env.GEMINI_API_KEY || settings.apiKey;
const SERVER = path.join(homedir(), ".gemini/extensions/nanobanana/mcp-server/dist/index.js");

// The coherence lock for isolated objects: cool carved stone + warm torch
// punctuation, seen from DIRECTLY overhead, on a plain warm-dark plate so
// isolate_objects.py can seal-then-flood the background cleanly.
const STYLE =
  "hand-illustrated painterly fantasy game art, warm torch-lit medieval dungeon, " +
  "COOL grey-blue carved-stone base with WARM ember-orange torch light pooling only " +
  "at the object's own glow, STRICT TOP-DOWN orthographic bird's-eye view seen from " +
  "DIRECTLY overhead (no side face, flat-lay footprint that fills the frame), soft " +
  "ambient-occlusion contact shadow, isolated single object centered on a plain flat " +
  "warm-dark near-black background (#1f1812), no text, no border, no grid, no UI.";

// The carried relic (heart): a gem TUMBLING in mid-air. Deliberately OMITS the
// "contact shadow" the STYLE suffix asks for — a contact shadow instructs a
// ground plane, which is exactly why the model kept baking a stone base under
// the gem. The heart is drawn standalone (on the pedestal AND lifted, riding a
// carrier — global.nim:2328), so ANY baked base is a defect.
const GEM =
  "hand-illustrated painterly fantasy game art, a faceted crystal gemstone " +
  "TUMBLING weightless through empty mid-air with NO ground, NO surface, NO " +
  "floor, NO shadow anywhere, seen from directly overhead, isolated dead-center " +
  "on a plain flat warm-dark near-black background (#1f1812), the gem alone " +
  "fills the frame, no text, no border, no grid, no UI.";

// The two full-bleed tile textures: seamless, evenly lit, no single object.
const SEAMLESS =
  "hand-illustrated painterly fantasy game art, cool grey-blue carved dungeon stone, " +
  "top-down orthographic bird's-eye view seen from directly overhead, seamless " +
  "perfectly tileable, even ambient lighting edge-to-edge, no vignette, no single " +
  "focal object, no torch, no text, no border, no grid, no UI.";

const ASSETS = [
  {
    key: "floor", seamless: true, seed: 73,
    prompt:
      "A seamless tileable worn DUNGEON STONE FLOOR seen from directly overhead. FINE, EVEN, " +
      "LOW-CONTRAST weathered grey-brown stone — a continuous ground surface, NOT a grid of " +
      "large distinct flagstones. Only faint hairline cracks, subtle grime and speckle, gentle " +
      "wear; NO large tiles, NO bold mortar lines, NO single focal feature, NO dominant stone " +
      "that would repeat as a visible grid. The whole tile reads as ONE smooth continuous stone " +
      "expanse. NO team color, NO glow, NO gradient across the tile, uniform flat ambient light. ",
  },
  {
    key: "wall", seamless: true, seed: 88,
    prompt:
      "A seamless tileable medieval dungeon STONE-BLOCK WALL seen from directly overhead, the " +
      "flat TOP of thick raised masonry. Cool grey carved-stone blocks in a running-bond " +
      "pattern with DEEP recessed mortar seams that cast soft ambient-occlusion shadow, each " +
      "block gently BEVELED at its edges with a subtle top-lit highlight so it reads as SOLID " +
      "RAISED STONE with real thickness and volume, chisel marks and weathering across the " +
      "block faces. Clearly heavier and darker than a floor. NOT a side elevation, NOT flat. ",
  },
  {
    key: "crew_red", seed: 47,
    prompt:
      "A tiny game token of a hooded warrior photographed by a camera mounted on the CEILING " +
      "looking STRAIGHT DOWN — a pure MAP-PIN / bird's-eye footprint. You see ONLY the round " +
      "TOP of a domed grey helmet as a circle in the dead center, a small triangular RED " +
      "CLOTH HOOD-POINT jutting from one side of that circle as the single 'front' marker, " +
      "and a ring of NEUTRAL GREY chain-mail shoulders and a RED CLOTH CLOAK fanning outward " +
      "around the helmet. Absolutely NO face, NO eyes, NO legs, NO body, NO weapon, NO gun, " +
      "NO sword, NO tile or platform underneath — you are looking at the very TOP of the head " +
      "from above. Compact, ROUGHLY CIRCULAR/RADIALLY SYMMETRIC silhouette so it reads at any " +
      "rotation. Clean dark outline. The mail stays GREY; only the cloak and hood-point are RED. ",
  },
  {
    key: "heart_red", seed: 88, suffix: "gem",
    prompt:
      "A heart-shaped faceted VERMILLION-RED crystal gem, and only the gem. The heart " +
      "crystal FILLS the frame edge to edge and is suspended in empty dark air — there is " +
      "NOTHING beneath it: NO stone, NO disc, NO coin, NO medallion, NO plinth, NO pedestal, " +
      "NO plate, NO ring, NO base. Sharp angular crystal facets, a deep inner ember glow, " +
      "warm rim light on the top facets, a soft red halo bleeding into the dark. A precious " +
      "magical relic, NOT a cartoon valentine — dramatic gemstone sheen. ",
  },
  {
    key: "heart_blue", seed: 88, suffix: "gem",
    prompt:
      "A heart-shaped faceted CERULEAN-BLUE crystal gem, and only the gem. The heart " +
      "crystal FILLS the frame edge to edge and is suspended in empty dark air — there is " +
      "NOTHING beneath it: NO stone, NO disc, NO coin, NO medallion, NO plinth, NO pedestal, " +
      "NO plate, NO ring, NO base. Sharp angular crystal facets, a deep inner cold glow, " +
      "cool blue-white rim light on the top facets, a soft blue halo bleeding into the dark. " +
      "A precious magical relic, NOT a cartoon valentine — dramatic gemstone sheen. ",
  },
  {
    key: "pedestal_red", seed: 61,
    prompt:
      "A single carved-stone ALTAR PEDESTAL seen from directly overhead: a circular cool " +
      "grey-blue stone dais with carved runic channels on its top surface filled with " +
      "glowing VERMILLION-RED light seeping from the runes, a slight beveled thickness at " +
      "the rim, ambient-occlusion at the base. The heart relic will sit on top. ",
  },
  {
    key: "pedestal_blue", seed: 61,
    prompt:
      "A single carved-stone ALTAR PEDESTAL seen from directly overhead: a circular cool " +
      "grey-blue stone dais with carved runic channels on its top surface filled with " +
      "glowing CERULEAN-BLUE light seeping from the runes, a slight beveled thickness at " +
      "the rim, ambient-occlusion at the base. The heart relic will sit on top. ",
  },
];

function gen(prompt, seed) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [SERVER], {
      cwd: OUT,
      env: { ...process.env, NANOBANANA_API_KEY: key, NANOBANANA_MODEL: "gemini-2.5-flash-image" },
      stdio: ["pipe", "pipe", "inherit"],
    });
    let buf = "";
    const send = (o) => child.stdin.write(JSON.stringify(o) + "\n");
    child.stdout.on("data", (d) => {
      buf += d.toString();
      let nl;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl).trim(); buf = buf.slice(nl + 1);
        if (!line) continue;
        let m; try { m = JSON.parse(line); } catch { continue; }
        if (m.id === 1) send({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "generate_image", arguments: { prompt, seed } } });
        else if (m.id === 2) { const t = m.result?.content?.map((c) => c.text).join("\n") ?? ""; child.kill(); resolve(t); }
      }
    });
    send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "nb", version: "1" } } });
    send({ jsonrpc: "2.0", method: "notifications/initialized", params: {} });
    setTimeout(() => { child.kill(); resolve("TIMEOUT"); }, 180000);
  });
}

const onlyArg = (process.argv.find((a) => a.startsWith("only=")) || "").slice(5);
const only = onlyArg ? new Set(onlyArg.split(",")) : null;
for (const a of ASSETS) {
  if (only && !only.has(a.key)) continue;
  const suffix = a.suffix === "gem" ? GEM : a.seamless ? SEAMLESS : STYLE;
  process.stdout.write(`[gen] ${a.key} (seed ${a.seed}) … `);
  const out = await gen(a.prompt + suffix, a.seed);
  const file = (out.match(/Image saved to: (.+\.png)/) || [])[1] || out.split("\n").filter(Boolean).pop();
  console.log(file || "(no file)");
}
console.log("done.");
