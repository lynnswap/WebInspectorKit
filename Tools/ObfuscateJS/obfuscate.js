#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");

function parseArgs(args) {
  const parsed = {};
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (!arg.startsWith("--")) {
      continue;
    }
    const key = arg.slice(2);
    const next = args[i + 1];
    if (next && !next.startsWith("--")) {
      parsed[key] = next;
      i += 1;
    } else {
      parsed[key] = true;
    }
  }
  return parsed;
}

function normalizeMode(value) {
  if (!value) {
    return null;
  }
  const lowered = String(value).toLowerCase();
  if (lowered === "debug" || lowered === "release") {
    return lowered;
  }
  if (lowered === "auto") {
    return null;
  }
  return null;
}

function resolveMode(modeArg, env) {
  const direct = normalizeMode(modeArg);
  if (direct) {
    return direct;
  }
  const override = normalizeMode(env.WEBINSPECTORKIT_OBFUSCATE_MODE);
  if (override) {
    return override;
  }
  const config = normalizeMode(env.SWIFT_BUILD_CONFIGURATION || env.CONFIGURATION);
  if (config) {
    return config;
  }
  const optimization = typeof env.SWIFT_OPTIMIZATION_LEVEL === "string"
    ? env.SWIFT_OPTIMIZATION_LEVEL.toLowerCase()
    : "";
  if (optimization === "-onone") {
    return "debug";
  }
  if (optimization.startsWith("-o")) {
    return "release";
  }
  const conditions = typeof env.SWIFT_ACTIVE_COMPILATION_CONDITIONS === "string"
    ? env.SWIFT_ACTIVE_COMPILATION_CONDITIONS
    : "";
  if (conditions.length > 0) {
    const tokens = conditions
      .split(/[ ,;]+/)
      .map((token) => token.toLowerCase())
      .filter((token) => token.length > 0);
    if (tokens.includes("debug")) {
      return "debug";
    }
    if (tokens.length > 0) {
      return "release";
    }
  }
  return "debug";
}

function loadConfig(configPath) {
  if (!configPath || !fs.existsSync(configPath)) {
    return { enabled: false, exclude: [], reservedNames: [] };
  }
  const raw = fs.readFileSync(configPath, "utf8");
  const parsed = JSON.parse(raw);
  return {
    enabled: parsed.enabled === true,
    exclude: Array.isArray(parsed.exclude) ? parsed.exclude : [],
    reservedNames: Array.isArray(parsed.reservedNames) ? parsed.reservedNames : [],
  };
}

function collectScriptFiles(directory) {
  const results = [];
  const entries = fs.readdirSync(directory, { withFileTypes: true });
  for (const entry of entries) {
    const fullPath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      results.push(...collectScriptFiles(fullPath));
      continue;
    }
    if (entry.isFile() && entry.name.endsWith(".js")) {
      results.push(fullPath);
      continue;
    }
    if (entry.isFile() && entry.name.endsWith(".ts") && !entry.name.endsWith(".d.ts")) {
      results.push(fullPath);
    }
  }
  return results;
}

function collectEntryFiles(directory) {
  const presetsDir = path.join(directory, "Presets");
  if (!fs.existsSync(presetsDir)) {
    return [];
  }
  return collectScriptFiles(presetsDir);
}

async function bundleEntry(entryPath, esbuild, debugDefine) {
  const result = await esbuild.build({
    entryPoints: [entryPath],
    bundle: true,
    write: false,
    format: "iife",
    platform: "browser",
    target: "es2024",
    logLevel: "silent",
    define: {
      __PD_DEBUG__: debugDefine,
    },
    loader: {
      ".ts": "ts"
    }
  });
  if (!result.outputFiles || result.outputFiles.length === 0) {
    throw new Error(`Failed to bundle entry: ${entryPath}`);
  }
  return result.outputFiles[0].text;
}

function loadTypeScript() {
  try {
    return require("typescript");
  } catch (err) {
    console.error("Missing typescript. Run: (cd Tools/ObfuscateJS && pnpm install)");
    process.exit(1);
  }
}

function loadEsbuild() {
  try {
    return require("esbuild");
  } catch (err) {
    console.error("Missing esbuild. Run: (cd Tools/ObfuscateJS && pnpm install)");
    process.exit(1);
  }
}

function getScriptName(filePath) {
  return path.basename(filePath, path.extname(filePath));
}

function replaceDebugDefines(source, debugDefine) {
  if (!debugDefine) {
    return source;
  }
  return source.replace(/\b__PD_DEBUG__\b/g, debugDefine);
}

function containsModuleSyntax(source) {
  return /(^|\n)\s*(import|export)\s/m.test(source);
}

function transpileTypeScript(source, filePath, ts) {
  const moduleKind = Object.prototype.hasOwnProperty.call(ts.ModuleKind, "ESNext")
    ? ts.ModuleKind.ESNext
    : ts.ModuleKind.ES2022;
  const result = ts.transpileModule(source, {
    fileName: filePath,
    compilerOptions: {
      target: ts.ScriptTarget.ES2024,
      module: moduleKind
    }
  });
  const diagnostics = result.diagnostics || [];
  const errors = diagnostics.filter((diagnostic) => diagnostic.category === ts.DiagnosticCategory.Error);
  if (errors.length > 0) {
    const host = {
      getCanonicalFileName: (name) => name,
      getCurrentDirectory: () => process.cwd(),
      getNewLine: () => "\n"
    };
    throw new Error(ts.formatDiagnosticsWithColorAndContext(errors, host));
  }
  return result.outputText;
}

function ensureDirectory(filePath) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
}

function toBase64(text) {
  return Buffer.from(text, "utf8").toString("base64");
}

function renderSwift(scripts) {
  const names = Object.keys(scripts).sort();
  const lines = [];
  lines.push("// Generated by Tools/ObfuscateJS/obfuscate.js. Do not edit.");
  lines.push("import Foundation");
  lines.push("");
  lines.push("enum BundledJavaScriptData {");
  lines.push("    static let scripts: [String: String] = [");
  for (const name of names) {
    const base64 = toBase64(scripts[name]);
    lines.push(`        \"${name}\": decode(\"${base64}\"),`);
  }
  lines.push("    ]");
  lines.push("");
  lines.push("    private static func decode(_ base64: String) -> String {");
  lines.push("        guard let data = Data(base64Encoded: base64) else {");
  lines.push("            return \"\"");
  lines.push("        }");
  lines.push("        return String(data: data, encoding: .utf8) ?? \"\"");
  lines.push("    }");
  lines.push("}");
  lines.push("");
  return lines.join("\n");
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const inputDir = args.input;
  const outputFile = args.output;
  const configPath = args.config;
  const mode = resolveMode(args.mode, process.env);
  if (!inputDir || !outputFile) {
    console.error("Usage: obfuscate.js --input <dir> --output <file> --config <file> --mode <debug|release>");
    process.exit(1);
  }

  const config = loadConfig(configPath);
  const exclude = new Set(config.exclude.map((value) => String(value)));
  const reservedNames = config.reservedNames.map((value) => String(value));
  const shouldObfuscate = config.enabled && mode !== "debug";
  const debugDefine = mode === "debug" ? "true" : "false";

  let terser = null;
  if (shouldObfuscate) {
    try {
      terser = require("terser");
    } catch (err) {
      console.error("Missing terser. Run: (cd Tools/ObfuscateJS && pnpm install)");
      process.exit(1);
    }
  }

  const scripts = {};
  const entryFiles = collectEntryFiles(inputDir).sort();
  const entryNames = new Set();

  if (entryFiles.length > 0) {
    const esbuild = loadEsbuild();
    for (const entryPath of entryFiles) {
      const name = getScriptName(entryPath);
      if (entryNames.has(name)) {
        throw new Error(`Duplicate JS module name: ${name}`);
      }
      entryNames.add(name);
      if (Object.prototype.hasOwnProperty.call(scripts, name)) {
        throw new Error(`Duplicate JS module name: ${name}`);
      }
      const source = await bundleEntry(entryPath, esbuild, debugDefine);
      if (!shouldObfuscate || exclude.has(name) || containsModuleSyntax(source)) {
        scripts[name] = source;
        continue;
      }
      const result = await terser.minify(source, {
        compress: true,
        mangle: {
          toplevel: true,
          reserved: reservedNames,
        },
        format: {
          comments: false,
        },
      });
      if (!result || result.error || !result.code) {
        const error = result && result.error ? result.error : new Error("Unknown terser failure");
        throw error;
      }
      scripts[name] = result.code;
    }
  }

  const files = collectScriptFiles(inputDir);
  const tsFiles = files.filter((filePath) => filePath.endsWith(".ts"));
  const ts = tsFiles.length > 0 ? loadTypeScript() : null;
  for (const filePath of files) {
    const name = getScriptName(filePath);
    if (entryNames.has(name)) {
      continue;
    }
    if (Object.prototype.hasOwnProperty.call(scripts, name)) {
      throw new Error(`Duplicate JS module name: ${name}`);
    }
    let source = fs.readFileSync(filePath, "utf8");
    if (filePath.endsWith(".ts")) {
      if (!ts) {
        throw new Error("TypeScript not available");
      }
      source = transpileTypeScript(source, filePath, ts);
    }
    source = replaceDebugDefines(source, debugDefine);
    if (!shouldObfuscate || exclude.has(name) || containsModuleSyntax(source)) {
      scripts[name] = source;
      continue;
    }
    const result = await terser.minify(source, {
      compress: true,
      mangle: {
        toplevel: true,
        reserved: reservedNames,
      },
      format: {
        comments: false,
      },
    });
    if (!result || result.error || !result.code) {
      const error = result && result.error ? result.error : new Error("Unknown terser failure");
      throw error;
    }
    scripts[name] = result.code;
  }

  const output = renderSwift(scripts);
  ensureDirectory(outputFile);
  fs.writeFileSync(outputFile, output, "utf8");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
