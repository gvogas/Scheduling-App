"use strict";

// Fails a deploy that would narrow any callable's payload allowlist.

const {execFileSync} = require("child_process");
const {readFileSync} = require("fs");

const CALL = /\b(assertAdminCall|assertActiveCall|assertPayloadShape)\s*\(/g;
const ARGS = new RegExp(
    /\s*req(?:\.data)?\s*,\s*new Set\(\s*/.source +
    /(?:\[([^\]]*)\]\s*)?\)\s*,?\s*\)/.source, "y");
const OWNER = /(?:function\s+(\w+)\s*\(|const\s+(\w+)\s*=\s*onCall\()/g;
const EXCLUDED_DIR = /^(?:node_modules|__tests__|scripts|coverage)\//;
const EXCLUDED_FILE = /^(?:security|jest\.config|\.eslintrc)\.js$/;

/**
 * Whether a call match is a real guard call and not a definition or prose.
 * @param {string} source The module source.
 * @param {number} index Offset of the matched name.
 * @return {boolean} True when it is an invocation in code.
 */
function isInvocation(source, index) {
  const lineStart = source.lastIndexOf("\n", index - 1) + 1;
  const before = source.slice(lineStart, index);
  if (/^\s*(?:\/\/|\/?\*)/.test(before)) return false;
  return !/function\s*\*?\s*$/.test(before);
}

/**
 * The string keys of an inline array body, or null when it holds anything
 * else (a variable, a spread, a call).
 * @param {string} body Text between the brackets.
 * @return {?Array<string>} Keys in order.
 */
function parseKeys(body) {
  const stripped = body.replace(/\/\/[^\n]*/g, "")
      .replace(/\/\*[\s\S]*?\*\//g, "");
  const keys = [];
  const rest = stripped.replace(/"([^"\\]+)"|'([^'\\]+)'/g, (_, a, b) => {
    keys.push(a || b);
    return "";
  });
  return /^[\s,]*$/.test(rest) ? keys : null;
}

/**
 * Inline allowlists in one source file, keyed by the owning handler.
 * Throws on any guard call whose allowlist is not an inline literal, so an
 * unreadable shape fails the deploy check instead of being skipped.
 * @param {string} source A functions module.
 * @return {!Map<string, !Set<string>>} Owner name to its allowed keys.
 */
function extractAllowlists(source) {
  const owners = [...source.matchAll(OWNER)]
      .map((m) => ({index: m.index, name: m[1] || m[2]}));
  const result = new Map();
  for (const match of source.matchAll(CALL)) {
    if (!isInvocation(source, match.index)) continue;
    ARGS.lastIndex = match.index + match[0].length;
    const args = ARGS.exec(source);
    const keys = args ? parseKeys(args[1] || "") : null;
    if (keys === null) {
      const line = source.slice(0, match.index).split("\n").length;
      throw new Error(
          `cannot read the allowlist of ${match[1]}( at line ${line}: ` +
          "it must be an inline `new Set([\"key\", ...])` literal " +
          "(extend scripts/deploy/allowlist_diff.js before using another " +
          "shape).");
    }
    const owner = owners.filter((o) => o.index < match.index).pop();
    const name = owner ? owner.name : "(module)";
    const set = result.get(name) || new Set();
    keys.forEach((key) => set.add(key));
    result.set(name, set);
  }
  return result;
}

/**
 * Keys present at the base and gone at HEAD.
 * @param {!Map<string, !Set<string>>} base Allowlists at the deployed sha.
 * @param {!Map<string, !Set<string>>} head Allowlists in the working tree.
 * @return {{removed: !Array<{owner: string, key: string}>,
 *     missingOwners: !Array<string>}} What narrowed, and owners not found.
 */
function removedKeys(base, head) {
  const removed = [];
  const missingOwners = [];
  for (const [owner, keys] of base) {
    const now = head.get(owner);
    if (!now) {
      missingOwners.push(owner);
      continue;
    }
    for (const key of keys) {
      if (!now.has(key)) removed.push({owner, key});
    }
  }
  return {removed, missingOwners};
}

/**
 * Compares every source file at the base against HEAD.
 * @param {{list: function(): !Array<string>,
 *     read: function(string): ?string}} base Files at the deployed sha.
 * @param {{list: function(): !Array<string>,
 *     read: function(string): ?string}} head Files in the working tree.
 * @return {{removed: !Array<{file: string, owner: string, key: string}>,
 *     missingOwners: !Array<{file: string, owner: string}>}} Findings.
 */
function compareTrees(base, head) {
  const files = [...new Set([...base.list(), ...head.list()])].sort()
      .filter((file) => file.endsWith(".js") &&
        !EXCLUDED_DIR.test(file) && !EXCLUDED_FILE.test(file));
  const headLists = new Map();
  const removed = [];
  const vanished = [];
  for (const file of files) {
    const headSource = head.read(file);
    const baseSource = base.read(file);
    let baseLists;
    try {
      headLists.set(file,
          extractAllowlists(headSource === null ? "" : headSource));
      if (baseSource === null) continue;
      baseLists = extractAllowlists(baseSource);
    } catch (err) {
      throw new Error(`${file}: ${err.message}`);
    }
    const result = removedKeys(baseLists, headLists.get(file));
    result.removed.forEach((r) => removed.push({file, ...r}));
    result.missingOwners.forEach((owner) =>
      vanished.push({file, owner, keys: baseLists.get(owner)}));
  }
  // An owner that moved files (a module split) is matched by name, but only
  // when exactly one HEAD file defines it.
  const missingOwners = [];
  for (const {file, owner, keys} of vanished) {
    const homes = [...headLists].filter(([, lists]) => lists.has(owner));
    if (homes.length !== 1) {
      missingOwners.push({file, owner});
      continue;
    }
    const [newFile, lists] = homes[0];
    for (const key of keys) {
      if (!lists.get(owner).has(key)) {
        removed.push({file: newFile, owner, key});
      }
    }
  }
  return {removed, missingOwners};
}

/**
 * Runs git and returns its stdout.
 * @param {!Array<string>} args Git arguments.
 * @return {string} Stdout.
 */
function runGit(args) {
  return execFileSync("git", args,
      {encoding: "utf8", stdio: ["ignore", "pipe", "pipe"]});
}

/**
 * The real file sources: `git` at the base sha, the working tree at HEAD.
 * @param {string} baseSha The last deployed sha.
 * @param {function(!Array<string>): string} git Runs git, returning stdout.
 * @return {{base: !Object, head: !Object}} Arguments for `compareTrees`.
 */
function gitTrees(baseSha, git = runGit) {
  git(["rev-parse", "--verify", `${baseSha}^{commit}`]);
  const lines = (out) => out.split("\n").filter(Boolean);
  let listed;
  const baseList = () => {
    if (!listed) {
      listed = lines(git(["ls-tree", "-r", "--name-only", baseSha]));
    }
    return listed;
  };
  return {
    base: {
      list: baseList,
      // Absent at the base is null; a listed file git cannot show throws.
      read: (file) => baseList().includes(file) ?
        git(["show", `${baseSha}:./${file}`]) : null,
    },
    head: {
      list: () => lines(git(["ls-files", "*.js"])),
      read: (file) => {
        try {
          return readFileSync(file, "utf8");
        } catch (err) {
          return null;
        }
      },
    },
  };
}

/**
 * CLI: run from `functions/`, `node scripts/deploy/allowlist_diff.js <sha>`.
 * @param {!Array<string>} argv Arguments after node + script.
 * @param {function(!Array<string>): string} git Runs git, returning stdout.
 * @return {number} Exit code.
 */
function main(argv, git = runGit) {
  const [baseSha] = argv;
  if (!baseSha) {
    console.error("::error::usage: allowlist_diff.js <last-deployed-sha>");
    return 1;
  }
  let found;
  try {
    const trees = gitTrees(baseSha, git);
    found = compareTrees(trees.base, trees.head);
  } catch (err) {
    console.error(`::error::allowlist check could not run: ${err.message}`);
    return 1;
  }
  for (const {file, owner, key} of found.removed) {
    console.error(
        `::error file=functions/${file}::${owner} no longer accepts ` +
        `"${key}". A shipped build that still sends it gets ` +
        "unexpected-field. Keep it accepted-and-ignored with a " +
        "#compat-<version> tag (.claude/rules/security.md).");
  }
  for (const {file, owner} of found.missingOwners) {
    console.log(
        `::warning file=functions/${file}::${owner} had an allowlist at ` +
        `${baseSha} and is not found now — renamed or deleted? Check it ` +
        "by hand.");
  }
  return found.removed.length > 0 ? 1 : 0;
}

if (require.main === module) {
  process.exitCode = main(process.argv.slice(2));
}

module.exports = {
  extractAllowlists, removedKeys, compareTrees, gitTrees, main,
};
