package util;

import util.ModuleDiagnostics;
import util.StdConfigMacro;

using StringTools;

class ProjectDiagnostics {
    public static function autoImport(hxmlPath:String, dryRun:Bool):Void {
        var parsed = parseHxml(hxmlPath);
        var cpRoots = mapKeysToArray(parsed.classpaths);
        if (cpRoots.length == 0) return;

        var libRoots = resolveLibClasspaths(parsed.libs);
        var stdRoots = StdConfigMacro.getStdRoots();
        var allRoots = dedup(cpRoots.concat(libRoots).concat(stdRoots));

        trace("allRoots: " + allRoots);

        var allFiles = collectAllHxFiles(allRoots);
       // trace("allFiles: " + allFiles);
        var classpathFiles = collectAllHxFiles(cpRoots);

        var metaIndex = buildTypeAndCanonicalMeta(allRoots, allFiles, cpRoots, stdRoots);
        var typeToCanonicals = metaIndex.typeToCanonicals;
        var canonicalMeta = metaIndex.canonicalMeta;
        var resolvedTypeToCanonical = resolveAmbiguousTypes(typeToCanonicals, canonicalMeta, parsed.targets);

        var filesProcessed = 0;
        var filesChanged = 0;
        for (f in classpathFiles) {
            trace("f: " + f);
            var depTypes:Array<String> = mdCall("getDependentTypes", f);
            trace("depTypes: " + depTypes);
            var importedNames:Array<String> = mdCall("getImports", f);
            trace("importedNames: " + importedNames);
            var importedSet:Map<String, Bool> = new Map();
            for (n in importedNames) importedSet.set(n, true);

            var toAdd = new Array<String>();
            for (t in depTypes) {
                if (importedSet.exists(t)) continue;
                var canonical = resolvedTypeToCanonical.get(t);
                trace("trying to match " + t + " to " + canonical);
                if (canonical == null) continue;
                toAdd.push(canonical);
            }
            var uniqCanonicals = dedup(toAdd);
            var res = insertImports(f, uniqCanonicals, dryRun);
            filesProcessed++;
            if (res.changed) {
                filesChanged++;
                Sys.println((dryRun ? "[DRY]" : "[FIX]") + " " + f + " - added " + res.addedCount + " import(s)");
            }
        }
        Sys.println("Processed " + filesProcessed + " files. " + (dryRun ? "Would change " : "Changed ") + filesChanged + " files.");
    }


    static inline function mdCall(method:String, path:String):Array<String> {
        var fn:Dynamic = Reflect.field(ModuleDiagnostics, method);
        var res:Dynamic = Reflect.callMethod(ModuleDiagnostics, fn, [path]);
        return cast res;
    }


    static function insertImports(filePath:String, canonicals:Array<String>, dryRun:Bool):{ changed:Bool, addedCount:Int } {
        if (canonicals == null || canonicals.length == 0) return { changed: false, addedCount: 0 };
        var content = sys.io.File.getContent(filePath);
        var imports = findImports(content);
        var existing:Map<String, Bool> = new Map();
        for (imp in imports) {
            if (imp.hasWildcard) continue;
            var cur = imp.pathSegments.join(".");
            existing.set(cur, true);
        }
        var toInsert = new Array<String>();
        for (c in canonicals) if (!existing.exists(c)) toInsert.push(c);
        if (toInsert.length == 0) return { changed: false, addedCount: 0 };
        toInsert.sort(Reflect.compare);

        var nl = detectNewline(content);
        var insertPos = -1;
        if (imports.length > 0) {
            var last = imports[imports.length - 1];
            insertPos = last.end;
        } else {
            var pkgEnd = findPackageEnd(content);
            insertPos = pkgEnd >= 0 ? pkgEnd : 0;
        }

        var prefix = content.substring(0, insertPos);
        var suffix = content.substring(insertPos, content.length);

        var sb = new StringBuf();
        var needsLeadingNl = prefix.length > 0 && !prefix.endsWith(nl);
        if (needsLeadingNl) sb.add(nl);
        for (c in toInsert) sb.add("import " + c + ";" + nl);
        var mid = sb.toString();
        var newContent = prefix + mid + suffix;
        if (!dryRun) sys.io.File.saveContent(filePath, newContent);
        return { changed: true, addedCount: toInsert.length };
    }

    static function detectNewline(s:String):String {
        var idx = s.indexOf("\r\n");
        if (idx != -1) return "\r\n";
        return "\n";
    }

    static function findPackageEnd(s:String):Int {
        var i = 0;
        var len = s.length;
        while (i < len) {
            var ch = s.charAt(i);
            if (isWS(ch)) { i++; continue; }
            if (isWordStartAt(s, i) && matchWord(s, i, "package")) {
                i += "package".length;
                i = skipWS(s, i);
                i = seekSemicolon(s, i);
                return i < len ? i + 1 : len;
            }
            break;
        }
        return -1;
    }

    private static function isWS(ch:String):Bool {
        return ch == " " || ch == "\t" || ch == "\r" || ch == "\n";
    }
    private static function isWordStart(ch:String):Bool {
        return (ch >= "A" && ch <= "Z") || (ch >= "a" && ch <= "z") || ch == "_";
    }
    private static function isWordChar(ch:String):Bool {
        return isWordStart(ch) || (ch >= "0" && ch <= "9");
    }
    private static function isWordStartAt(s:String, i:Int):Bool {
        return i < s.length && isWordStart(s.charAt(i));
    }
    private static function readIdent(s:String, i:Int):String {
        var j = i;
        while (j < s.length) {
            var ch = s.charAt(j);
            if (!isWordChar(ch)) break;
            j++;
        }
        return s.substring(i, j);
    }
    private static function skipWS(s:String, i:Int):Int {
        var j = i;
        while (j < s.length && isWS(s.charAt(j))) j++;
        return j;
    }
    private static function matchWord(s:String, i:Int, w:String):Bool {
        var L = w.length;
        if (i + L > s.length) return false;
        if (s.substr(i, L) != w) return false;
        var beforeOK = (i == 0) || !isWordChar(s.charAt(i - 1));
        var afterOK = (i + L >= s.length) || !isWordChar(s.charAt(i + L));
        return beforeOK && afterOK;
    }
    private static function seekSemicolon(s:String, i:Int):Int {
        var j = i;
        var len = s.length;
        var state = 0;
        while (j < len) {
            var ch = s.charAt(j);
            if (state == 0) {
                if (ch == ";") return j;
                if (ch == '"') { state = 3; j++; continue; }
                if (ch == "'") { state = 4; j++; continue; }
                if (ch == "/" && j + 1 < len) {
                    var ch2 = s.charAt(j + 1);
                    if (ch2 == "/") { state = 1; j += 2; continue; }
                    if (ch2 == "*") { state = 2; j += 2; continue; }
                }
                j++;
            } else if (state == 1) {
                if (ch == "\n") state = 0;
                j++;
            } else if (state == 2) {
                if (ch == "*" && j + 1 < len && s.charAt(j + 1) == "/") { state = 0; j += 2; }
                else j++;
            } else if (state == 3) {
                if (ch == "\\") { j += 2; }
                else if (ch == '"') { state = 0; j++; }
                else j++;
            } else if (state == 4) {
                if (ch == "\\") { j += 2; }
                else if (ch == "'") { state = 0; j++; }
                else j++;
            }
        }
        return j;
    }

    private static function findImports(s:String):Array<{ start:Int, end:Int, pathSegments:Array<String>, hasWildcard:Bool, alias:Null<String> }> {
        var out = new Array<{ start:Int, end:Int, pathSegments:Array<String>, hasWildcard:Bool, alias:Null<String> }>();
        var i = 0;
        var len = s.length;
        var depth = 0;
        var state = 0;
        while (i < len) {
            var ch = s.charAt(i);
            if (state == 0) {
                if (ch == "/" && i + 1 < len) {
                    var ch2 = s.charAt(i + 1);
                    if (ch2 == "/") { state = 1; i += 2; continue; }
                    if (ch2 == "*") { state = 2; i += 2; continue; }
                }
                if (ch == '"') { state = 3; i++; continue; }
                if (ch == "'") { state = 4; i++; continue; }
                if (ch == "{") { depth++; i++; continue; }
                if (ch == "}") { if (depth > 0) depth--; i++; continue; }
                if (depth == 0 && isWordStart(ch) && matchWord(s, i, "import")) {
                    var start = i;
                    i += "import".length;
                    var j = skipWS(s, i);
                    var segments = new Array<String>();
                    var hasWildcard = false;
                    var stop = false;
                    while (!stop) {
                        j = skipWS(s, j);
                        if (j >= len) break;
                        var c = s.charAt(j);
                        if (c == "*") { hasWildcard = true; j++; break; }
                        if (!isWordStartAt(s, j)) { j = seekSemicolon(s, j); break; }
                        var seg = readIdent(s, j);
                        segments.push(seg);
                        j += seg.length;
                        j = skipWS(s, j);
                        if (j < len && s.charAt(j) == ".") { j++; continue; } else { break; }
                    }
                    j = skipWS(s, j);
                    var alias:Null<String> = null;
                    if (matchWord(s, j, "as")) {
                        j += "as".length;
                        j = skipWS(s, j);
                        if (isWordStartAt(s, j)) { var al = readIdent(s, j); alias = al; j += al.length; }
                    }
                    j = skipWS(s, j);
                    j = seekSemicolon(s, j);
                    var end = j < len ? j + 1 : len;
                    out.push({ start: start, end: end, pathSegments: segments, hasWildcard: hasWildcard, alias: alias });
                    i = end;
                    continue;
                }
                i++;
            } else if (state == 1) {
                if (ch == "\n") state = 0;
                i++;
            } else if (state == 2) {
                if (ch == "*" && i + 1 < len && s.charAt(i + 1) == "/") { state = 0; i += 2; }
                else i++;
            } else if (state == 3) {
                if (ch == "\\") i += 2; else if (ch == '"') { state = 0; i++; } else i++;
            } else if (state == 4) {
                if (ch == "\\") i += 2; else if (ch == "'") { state = 0; i++; } else i++;
            }
        }
        return out;
    }

    static inline function norm(p:String):String {
        return p.split("\\").join("/");
    }

    static function dedup(arr:Array<String>):Array<String> {
        var seen:Map<String, Bool> = new Map();
        var out = new Array<String>();
        for (v in arr) if (!seen.exists(v)) { seen.set(v, true); out.push(v); }
        return out;
    }

    static function mapKeysToArray(m:Map<String, Bool>):Array<String> {
        var out = new Array<String>();
        for (k in m.keys()) out.push(k);
        return out;
    }

    static function tokenizeHxml(s:String):Array<String> {
        var t = new Array<String>();
        var cur = new StringBuf();
        var inQuote = false;
        var quote = "";
        var i = 0;
        inline function flush() {
            var v = cur.toString();
            if (v.length > 0) { t.push(v); cur = new StringBuf(); }
        }
        while (i < s.length) {
            var ch = s.charAt(i);
            if (!inQuote && ch == "#") {
                flush();
                while (i < s.length && s.charAt(i) != "\n") i++;
                i++;
                continue;
            }
            if (!inQuote && isWS(ch)) { flush(); i++; continue; }
            if (ch == "'" || ch == '"') {
                if (!inQuote) { inQuote = true; quote = ch; i++; continue; }
                else if (quote == ch) { inQuote = false; quote = ""; i++; continue; }
                else { cur.add(ch); i++; continue; }
            }
            if (inQuote && ch == "\\") {
                if (i + 1 < s.length) { i++; cur.add(s.charAt(i)); i++; continue; }
            }
            cur.add(ch);
            i++;
        }
        flush();
        return t;
    }

    static function resolveLibClasspaths(libs:Array<String>):Array<String> {
        var roots = new Array<String>();
        for (lib in libs) {
            var p = new sys.io.Process("haxelib", ["path", lib]);
            var out = p.stdout.readAll().toString();
            p.close();
            var lines = out.split("\r\n").join("\n").split("\n");
            for (ln in lines) {
                var s = ln == null ? "" : ln.trim();
                if (s.length == 0) continue;
                if (s.charAt(0) == "-") continue;
                var candidate = norm(s);
                if (sys.FileSystem.exists(candidate) && sys.FileSystem.isDirectory(candidate)) {
                    roots.push(candidate);
                }
            }
        }
        return dedup(roots);
    }

    static function collectAllHxFiles(roots:Array<String>):Array<String> {
        var out = new Array<String>();
        var seen:Map<String, Bool> = new Map();
        for (r in roots) {
            if (!sys.FileSystem.exists(r) || !sys.FileSystem.isDirectory(r)) continue;
            var absRoot = norm(sys.FileSystem.fullPath(r));
            walk(absRoot, out, seen);
        }
        return out;
    }

    static function walk(dir:String, out:Array<String>, seen:Map<String, Bool>):Void {
        var entries = sys.FileSystem.readDirectory(dir);
        for (name in entries) {
            if (name == "." || name == "..") continue;
            var p = dir + "/" + name;
            if(isPlatformSpecificStd(p)) continue;
            var isDir = sys.FileSystem.isDirectory(p);
            if (isDir) {
                walk(p, out, seen);
            } else {
                if (haxe.io.Path.extension(name).toLowerCase() == "hx") {
                    var abs = norm(sys.FileSystem.fullPath(p));
                    if (!seen.exists(abs)) { seen.set(abs, true); out.push(abs); }
                }
            }
        }
    }

    static function buildTypeAndCanonicalMeta(
        roots:Array<String>,
        files:Array<String>,
        cpRoots:Array<String>,
        stdRoots:Array<String>
    ):{ typeToCanonicals:Map<String, Array<String>>, canonicalMeta:Map<String, { root:String, firstSeg:String, inStd:Bool, inClasspath:Bool }> } {
        var typeToCanonicals:Map<String, Array<String>> = new Map();
        var canonicalMeta:Map<String, { root:String, firstSeg:String, inStd:Bool, inClasspath:Bool }> = new Map();

        var cpSet:Map<String, Bool> = new Map();
        for (r in cpRoots) cpSet.set(r, true);
        var stdSet:Map<String, Bool> = new Map();
        for (r in stdRoots) stdSet.set(r, true);

        for (f in files) {
            var root = pickBestRootForFile(f, roots);
            if (root == null) continue;
            var mod = moduleInfoFromPath(root, f);
            var rel = norm(sys.FileSystem.fullPath(f));
            var rabs = norm(sys.FileSystem.fullPath(root));
            if (!rabs.endsWith("/")) rabs += "/";
            var relPath = rel.startsWith(rabs) ? rel.substr(rabs.length) : haxe.io.Path.withoutDirectory(rel);
            var dir = haxe.io.Path.directory(relPath);
            var firstSeg = "";
            if (dir != null && dir != "" && dir != ".") {
                var parts = dir.split("\\").join("/").split("/");
                for (p in parts) if (p != null && p != "") { firstSeg = p; break; }
            }
            var topTypes:Array<String> = mdCall("getModuleLevelFields", f);
            for (t in topTypes) {
                var canonical = (t == mod.moduleName) ? mod.fullModule : (mod.fullModule + "." + t);
                var arr = typeToCanonicals.get(t);
                if (arr == null) { arr = []; typeToCanonicals.set(t, arr); }
                arr.push(canonical);
                if (!canonicalMeta.exists(canonical)) {
                    canonicalMeta.set(canonical, {
                        root: root,
                        firstSeg: firstSeg,
                        inStd: stdSet.exists(root),
                        inClasspath: cpSet.exists(root)
                    });
                }
            }
        }
        return { typeToCanonicals: typeToCanonicals, canonicalMeta: canonicalMeta };
    }

    static function resolveAmbiguousTypes(
        typeToCanonicals:Map<String, Array<String>>,
        canonicalMeta:Map<String, { root:String, firstSeg:String, inStd:Bool, inClasspath:Bool }>,
        selectedTargets:Array<String>
    ):Map<String, String> {
        var result:Map<String, String> = new Map();
        var targets = ["hl", "cpp", "cs", "java", "js", "lua", "neko", "php", "python"];
        var coreStdDirs = ["eval", "haxe", "sys"];

        function contains(arr:Array<String>, v:String):Bool {
            for (x in arr) if (x == v) return true; return false;
        }

        function priorityOf(canonical:String):Int {
            var meta = canonicalMeta.get(canonical);
            if (meta == null) return 5;
            if (meta.inClasspath) return 1; // p1
            if (meta.inStd) {
                var first = meta.firstSeg;
                if (first == null || first == "") return 2; // p2
                if (contains(coreStdDirs, first)) return 3; // p3
                if (contains(targets, first)) {
                    return contains(selectedTargets, first) ? 4 : 5; // p4 else p5
                }
                return 2; // p2
            }
            return 5; // p5
        }

        for (t in typeToCanonicals.keys()) {
            var list = typeToCanonicals.get(t);
            if (list == null || list.length == 0) continue;
            var uniq = dedup(list);
            var best:String = null;
            var bestPri = 9999;
            uniq.sort(Reflect.compare);
            for (c in uniq) {
                var pri = priorityOf(c);
                if (pri < bestPri) { bestPri = pri; best = c; }
            }
            if (best != null) result.set(t, best);
        }
        return result;
    }

    
    // Prefer target-agnostic std module paths in imports by stripping leading
    // platform-specific std prefixes like "hl._std.", "cpp._std.", etc.
    static function isPlatformSpecificStd(modulePath:String):Bool {
        var s = modulePath;
        var dotStd = "._std.";
        if(!s.contains(dotStd)) return false;
        var targets = ["hl", "cpp", "cs", "java", "js", "lua", "neko", "php", "python"];
        for (target in targets) {
            if (s.contains(target + dotStd)) {
                return true;
            }
        }
        return false;
    }


    static function pickBestRootForFile(fileAbs:String, roots:Array<String>):String {
        var best:String = null;
        var bestLen = -1;
        for (r in roots) {
            var rr = r;
            if (!rr.endsWith("/")) rr += "/";
            if (fileAbs.startsWith(rr)) {
                if (rr.length > bestLen) { best = r; bestLen = rr.length; }
            }
        }
        return best;
    }

    static function moduleInfoFromPath(root:String, fileAbs:String):{ packagePath:String, moduleName:String, fullModule:String } {
        var r = norm(sys.FileSystem.fullPath(root));
        var f = norm(sys.FileSystem.fullPath(fileAbs));
        if (!r.endsWith("/")) r += "/";
        var rel = f.startsWith(r) ? f.substr(r.length) : haxe.io.Path.withoutDirectory(f);
        var dir = haxe.io.Path.directory(rel);
        var pkg = (dir == null || dir == "" || dir == ".") ? "" : dir.split("\\").join("/").split("/").filter(function(x) return x != "").join(".");
        var moduleName = haxe.io.Path.withoutExtension(haxe.io.Path.withoutDirectory(rel));
        var fullModule = pkg == "" ? moduleName : (pkg + "." + moduleName);
        return { packagePath: pkg, moduleName: moduleName, fullModule: fullModule };
    }
    static function parseHxml(hxmlPath:String):{ classpaths:Map<String, Bool>, libs:Array<String>, targets:Array<String> } {
        var cpSet:Map<String, Bool> = new Map();
        var libs = new Array<String>();
        var targets = new Array<String>();
        var visited:Map<String, Bool> = new Map();
        parseHxmlInner(norm(hxmlPath), cpSet, libs, targets, visited);
        return { classpaths: cpSet, libs: libs, targets: dedup(targets) };
    }

    static function parseHxmlInner(hxmlPath:String, cpSet:Map<String, Bool>, libs:Array<String>, targets:Array<String>, visited:Map<String, Bool>):Void {
        var abs = norm(sys.FileSystem.fullPath(hxmlPath));
        if (visited.exists(abs)) return;
        visited.set(abs, true);
        if (!sys.FileSystem.exists(abs)) return;
        var content = sys.io.File.getContent(abs);
        var tokens = tokenizeHxml(content);
        var baseDir = norm(haxe.io.Path.directory(abs));
        var i = 0;
        while (i < tokens.length) {
            var tok = tokens[i++];
            if (tok == null || tok.length == 0) continue;
            if (tok.charAt(0) == "@") {
                var inc = tok.substr(1);
                if (inc.length == 0) { if (i >= tokens.length) break; inc = tokens[i++]; }
                var incPath = inc;
                if (!haxe.io.Path.isAbsolute(incPath)) incPath = haxe.io.Path.normalize(haxe.io.Path.join([baseDir, incPath]));
                parseHxmlInner(norm(incPath), cpSet, libs, targets, visited);
                continue;
            }
            if (tok == "-cp" || tok == "-p" || tok == "--class-path") {
                if (i >= tokens.length) break;
                var p = tokens[i++];
                var cp = p;
                if (!haxe.io.Path.isAbsolute(cp)) cp = haxe.io.Path.normalize(haxe.io.Path.join([baseDir, cp]));
                cp = norm(cp);
                if (sys.FileSystem.exists(cp)) cpSet.set(cp, true);
                continue;
            }
            if (tok == "-lib" || tok == "--library") {
                if (i >= tokens.length) break;
                var libName = tokens[i++];
                libs.push(libName);
                continue;
            }
            // Capture targets
            switch (tok) {
                case "-js": if (i < tokens.length) { i++; targets.push("js"); } continue;
                case "-hl": if (i < tokens.length) { i++; targets.push("hl"); } continue;
                case "-neko": if (i < tokens.length) { i++; targets.push("neko"); } continue;
                case "-php": if (i < tokens.length) { i++; targets.push("php"); } continue;
                case "-swf": if (i < tokens.length) { i++; /*flash*/ } continue;
                case "-as3": if (i < tokens.length) { i++; /*as3*/ } continue;
                case "-cpp": if (i < tokens.length) { i++; targets.push("cpp"); } continue;
                case "-cs": if (i < tokens.length) { i++; targets.push("cs"); } continue;
                case "-java": if (i < tokens.length) { i++; targets.push("java"); } continue;
                case "-python": if (i < tokens.length) { i++; targets.push("python"); } continue;
                case "-lua": if (i < tokens.length) { i++; targets.push("lua"); } continue;
                default:
            }
            switch (tok) {
                case "-resource" | "-r" | "--resource" | "-D" | "--define" | "-js" | "-hl" | "-neko" | "-php" | "-swf" | "-as3" | "-cpp" | "-cs" | "-java" | "-python" | "-lua" | "-main" | "-m" | "-cmd" | "-dce" | "-swf-version" | "-swf-header" | "-xml" | "-json" | "-hxml":
                    if (i < tokens.length) i++;
                default:
            }
        }
    }
}