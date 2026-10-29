import fs from "node:fs/promises";
import path from "node:path";
import sharp from "sharp";

const root = process.cwd();
const icon = await fs.readFile(path.join(root, "assets/icon.svg"));
const og = await fs.readFile(path.join(root, "assets/og.svg"));
const app = path.join(root, "src/app");

await fs.writeFile(path.join(app, "icon.svg"), icon);
await sharp(icon, { density: 600 }).resize(64, 64).png().toFile(path.join(app, "icon.png"));
await sharp(icon, { density: 600 }).resize(180, 180).png().toFile(path.join(app, "apple-icon.png"));
await sharp(og, { density: 144 }).resize(1200, 630).png().toFile(path.join(app, "opengraph-image.png"));

const stat = async (file) => `${file}: ${(await fs.stat(file)).size} bytes`;
for (const file of ["icon.png", "apple-icon.png", "opengraph-image.png"]) {
  console.log(await stat(path.join(app, file)));
}
