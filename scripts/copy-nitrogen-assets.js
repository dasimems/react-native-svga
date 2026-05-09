#!/usr/bin/env node
/**
 * After `bob build`, the compiled SvgaPlayer.js sits at lib/module/SvgaPlayer.js
 * and references `../nitrogen/generated/shared/json/SvgaConfig.json`. From that
 * location the path resolves to `lib/nitrogen/...`, but the source-of-truth
 * nitrogen output lives at the package root. This script copies the JSON
 * assets into `lib/nitrogen/...` so the relative require resolves correctly
 * from the built output.
 */
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..');
const SOURCE = path.join(ROOT, 'nitrogen', 'generated', 'shared', 'json');
const TARGET = path.join(
  ROOT,
  'lib',
  'nitrogen',
  'generated',
  'shared',
  'json'
);

if (!fs.existsSync(SOURCE)) {
  console.warn(
    `[copy-nitrogen-assets] source missing: ${SOURCE} - did nitrogen run?`
  );
  process.exit(0);
}

fs.mkdirSync(TARGET, { recursive: true });

let copied = 0;
for (const entry of fs.readdirSync(SOURCE)) {
  if (!entry.endsWith('.json')) continue;
  fs.copyFileSync(path.join(SOURCE, entry), path.join(TARGET, entry));
  copied++;
}

console.log(
  `[copy-nitrogen-assets] copied ${copied} json file(s) to lib/nitrogen/generated/shared/json`
);
