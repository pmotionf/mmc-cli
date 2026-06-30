const fs = require("fs").promises;

module.exports = async ({ core }) => {
  // Parse `build.zig.zon` for version
  let version;
  const name = "mmc-cli";
  const raw = await fs.readFile("./build.zig.zon");
  const lines = raw.toString().split("\n");
  lines.forEach((line) => {
    line = line.trim();
    if (line.startsWith(".version")) {
      const parts = line.split("=");
      const version_raw = parts[1];
      const version_cleaned = version_raw
        .replaceAll('"', "")
        .replaceAll(",", "");
      version = version_cleaned.trim();
    }
  });

  core.exportVariable("NAME", name);
  core.exportVariable("VERSION", version);
};
