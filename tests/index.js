// Verifies that the installed dependency works correctly.
// Used by run-tests.sh after each package manager install.

const ms = require("ms");

const result = ms("2 days");
const expected = 172800000;

if (result !== expected) {
  console.error(`FAIL: ms('2 days') = ${result}, expected ${expected}`);
  process.exit(1);
}

console.log(`node    ${process.version}`);
console.log(`ms      ms('2 days') = ${result} ✓`);
