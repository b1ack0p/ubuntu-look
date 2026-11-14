// Syntax check for the JavaScript that ubuntu-look.sh writes: each file in
// ARGV is parsed as an ES module and never run. Prints one line for each file
// that does not parse, and exits 1 then.
//
//   gjs tests/parse-js.js <file>...
const GLib = imports.gi.GLib;

let bad = 0;
for (const file of ARGV) {
    const source = new TextDecoder().decode(GLib.file_get_contents(file)[1]);
    try {
        Reflect.parse(source, {target: 'module'});
    } catch (e) {
        print(`${file}: ${e.name}: ${e.message}`);
        bad = 1;
    }
}
imports.system.exit(bad);
