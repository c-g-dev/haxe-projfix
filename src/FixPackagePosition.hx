package;

import sys.io.File;
import sys.FileSystem;
import haxe.io.Path;
using StringTools;

class FixPackagePosition {
    static public function main() {
        var args = Sys.args();
        run(args);
    }

    public static function run(args:Array<String>) {
        if (args.length == 0 || args[0] == "-h" || args[0] == "--help") {
            Sys.println("Usage:");
            Sys.println("  haxe --run FixPackagePosition path/to/project.hxml");
            Sys.println("Options:");
            Sys.println("  -n, --dry-run   Do not write changes, only report");
            return;
        }

        var hxml = args[0];
        var dryRun = false;
        for (i in 1...args.length) if (args[i] == "--dry-run" || args[i] == "-n") dryRun = true;

        if (!FileSystem.exists(hxml)) { Sys.println("File not found: " + hxml); Sys.exit(1); }

        var cpSet:Map<String,Bool> = new Map();
        var visited:Map<String,Bool> = new Map();
        parseHxml(hxml, cpSet, visited);

        if (!cpSet.keys().hasNext()) {
            Sys.println("No -cp entries found in " + hxml);
            return;
        }

        var filesProcessed = 0;
        var filesChanged = 0;
        var processedFiles:Map<String,Bool> = new Map();

        for (root in cpSet.keys()) {
            if (!FileSystem.exists(root) || !FileSystem.isDirectory(root)) {
               Sys.println("Warning: classpath not found or not a directory: " + root);
               continue;
            }
            var hxFiles = collectHxFiles(root);
            for (f in hxFiles) {
               var absF = normSlash(FileSystem.fullPath(f));
               if (processedFiles.exists(absF)) continue;
               processedFiles.set(absF, true);

               var res = fixFileMovePackageToTop(f, dryRun);
               filesProcessed++;
               if (res.changed) {
                  filesChanged++;
                  var msg = res.message != null ? " - " + res.message : "";
                  Sys.println((dryRun ? "[DRY]" : "[FIX]") + " " + f + msg);
               }
            }
        }
        Sys.println('Processed $filesProcessed .hx files. ' + (dryRun ? 'Would change ' : 'Changed ') + filesChanged + ' files.');
    }

    static function detectEOL(s:String):String {
        var idx = s.indexOf("\r\n");
        if (idx != -1) return "\r\n";
        if (s.indexOf("\n") != -1) return "\n";
        return Sys.systemName() == "Windows" ? "\r\n" : "\n";
    }

    static function hasBOM(s:String):Bool {
        return s.length > 0 && s.charCodeAt(0) == 0xFEFF;
    }

    static function fixFileMovePackageToTop(filePath:String, dryRun:Bool):{ changed:Bool, message:String } {
        var content = File.getContent(filePath);
        var info = parseExistingPackage(content);
        if (!info.has) return { changed: false, message: null };

        var bomLen = hasBOM(content) ? 1 : 0;
        if (info.start == bomLen) return { changed: false, message: null };

        var nl = detectEOL(content);
        var pkgStmt = content.substring(info.start, info.end);
        var leading = content.substring(bomLen, info.start);
        var trailing = content.substring(info.end);

        var newContent = content.substring(0, bomLen) + pkgStmt + nl + leading + trailing;
        if (!dryRun) File.saveContent(filePath, newContent);
        return { changed: true, message: "moved package to top" };
    }

    static function parseHxml(hxmlPath:String, cpSet:Map<String,Bool>, visited:Map<String,Bool>):Void {
        var abs = normSlash(FileSystem.fullPath(hxmlPath));
        if (visited.exists(abs)) return;
        visited.set(abs, true);

        if (!FileSystem.exists(abs)) {
            Sys.println("Warning: .hxml not found: " + abs);
            return;
        }
        var content = File.getContent(abs);
        var tokens = tokenizeHxml(content);
        var baseDir = normSlash(Path.directory(abs));

        var i = 0;
        while (i < tokens.length) {
            var tok = tokens[i++];
            if (tok == null || tok.length == 0) continue;

            if (tok.charAt(0) == "@") {
               var inc = tok.substr(1);
               if (inc.length == 0) {
                  if (i >= tokens.length) { Sys.println("Warning: '@' with no filename in " + abs); break; }
                  inc = tokens[i++];
               }
               var incPath = inc;
               if (!Path.isAbsolute(incPath)) incPath = Path.normalize(Path.join([baseDir, incPath]));
               parseHxml(incPath, cpSet, visited);
               continue;
            }

            if (tok == "-cp" || tok == "-p" || tok == "--class-path") {
               if (i >= tokens.length) { Sys.println("Warning: Missing path after " + tok + " in " + abs); break; }
               var p = tokens[i++];
               var cp = p;
               if (!Path.isAbsolute(cp)) cp = Path.normalize(Path.join([baseDir, cp]));
               cp = normSlash(FileSystem.fullPath(cp));
               cpSet.set(cp, true);
               continue;
            }

            switch (tok) {
                case "-resource" | "-r" | "--resource" |
                     "-lib" | "--library" |
                     "-D" | "--define" |
                     "-js" | "-hl" | "-neko" | "-php" | "-swf" | "-as3" | "-cpp" | "-cs" | "-java" | "-python" | "-lua" |
                     "-main" | "-m" |
                     "-cmd" |
                     "-dce" |
                     "-swf-version" | "-swf-header" |
                     "-xml" | "-json" | "-hxml":
                    if (i < tokens.length) i++;
                default:
            }
        }
    }

    static function tokenizeHxml(s:String):Array<String> {
        var t = new Array<String>();
        var cur = new StringBuf();
        var inQuote = false;
        var quote = "";
        var i = 0;
        var len = s.length;

        inline function flush() {
            var v = cur.toString();
            if (v.length > 0) {
                t.push(v);
                cur = new StringBuf();
            }
        }

        while (i < len) {
            var ch = s.charAt(i);
            if (!inQuote && ch == "#") {
                flush();
                while (i < len && s.charAt(i) != "\n") i++;
                i++;
                continue;
            }
            if (!inQuote && (ch == " " || ch == "\t" || ch == "\r" || ch == "\n")) {
                flush();
                i++;
                continue;
            }
            if (ch == '"' || ch == "'") {
                if (!inQuote) {
                    inQuote = true; quote = ch; i++; continue;
                } else if (quote == ch) {
                    inQuote = false; quote = ""; i++; continue;
                } else {
                    cur.add(ch); i++; continue;
                }
            }
            if (inQuote && ch == "\\") {
                if (i + 1 < len) {
                    i++;
                    cur.add(s.charAt(i));
                    i++;
                    continue;
                }
            }
            cur.add(ch);
            i++;
        }
        flush();
        return t;
    }

    static function normSlash(p:String):String {
        return p == null ? null : p.split("\\").join("/");
    }

    static function collectHxFiles(root:String):Array<String> {
        var out = new Array<String>();
        var rootAbs = normSlash(FileSystem.fullPath(root));
        walk(rootAbs, out);
        return out;
    }

    static function walk(dir:String, out:Array<String>):Void {
        var entries = FileSystem.readDirectory(dir);
        for (name in entries) {
            if (name == "." || name == "..") continue;
            var path = dir + "/" + name;
            var isDir = FileSystem.isDirectory(path);
            if (isDir) {
                walk(path, out);
            } else {
                var ext = Path.extension(name);
                if (ext != null && ext.toLowerCase() == "hx") {
                    out.push(path);
                }
            }
        }
    }

    static function isWS(ch:String):Bool {
        return ch == " " || ch == "\t" || ch == "\r" || ch == "\n";
    }

    static function skipBOM(s:String, pos:Int):Int {
        if (pos == 0 && s.length > 0 && s.charCodeAt(0) == 0xFEFF) return 1;
        return pos;
    }

    static function skipWSAndComments(s:String, pos:Int):Int {
        var len = s.length;
        var i = pos;
        i = skipBOM(s, i);
        var moved = true;
        while (moved) {
            moved = false;
            while (i < len) {
                var ch = s.charAt(i);
                if (ch == " " || ch == "\t" || ch == "\r" || ch == "\n") { i++; moved = true; }
                else break;
            }
            if (i + 1 < len && s.charAt(i) == "/" && s.charAt(i + 1) == "/") {
                i += 2;
                while (i < len && s.charAt(i) != "\n") i++;
                moved = true;
                continue;
            }
            if (i + 1 < len && s.charAt(i) == "/" && s.charAt(i + 1) == "*") {
                var end = s.indexOf("*/", i + 2);
                if (end == -1) return len;
                i = end + 2;
                moved = true;
                continue;
            }
        }
        return i;
    }

    static function parseExistingPackage(s:String):{ has:Bool, start:Int, end:Int, name:String, headerEnd:Int } {
        var headerEnd = skipWSAndComments(s, 0);
        var i = headerEnd;
        var len = s.length;
        var has = false;
        var start = i;
        var end = i;
        var name:String = null;

        if (i + 7 <= len && s.substr(i, 7) == "package") {
            var after = i + 7;
            if (after >= len || isWS(s.charAt(after)) || s.charAt(after) == ";") {
                while (after < len && isWS(s.charAt(after))) after++;
                if (after < len && s.charAt(after) == ";") {
                    has = true;
                    start = i;
                    end = after + 1;
                    name = "";
                } else {
                    var semi = s.indexOf(";", after);
                    if (semi != -1) {
                        var raw = s.substring(after, semi);
                        has = true;
                        start = i;
                        end = semi + 1;
                        name = raw.trim();
                    }
                }
            }
        }
        return { has: has, start: start, end: end, name: name, headerEnd: headerEnd };
    }
}


