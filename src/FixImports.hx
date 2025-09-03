package;

import Map;
import StringBuf;
import Sys;
import haxe.ds.StringMap;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using StringTools;

private typedef ModuleInfo = {
	var packagePath:String; 
	var moduleName:String; 
	var fullModule:String; 
	var types:Array<String>;
}

private typedef ImportStmt = {
	var start:Int; 
	var end:Int; 
	var pathSegments:Array<String>; 
	var hasWildcard:Bool;
	var alias:Null<String>;
}

private typedef FixResult = {
	var changed:Bool;
	var messages:Array<String>;
}

class FixImports {
	static public function main() {
		var args = Sys.args();
		run(args);
	}

	public static function run(args:Array<String>) {
		if (args.length == 0 || args[0] == "-h" || args[0] == "--help") {
			Sys.println("Usage:");
			Sys.println("  haxe --run FixImports path/to/project.hxml [--dry-run]");
			return;
		}

		var hxml = args[0];
		var dryRun = args.indexOf("--dry-run") != -1 || args.indexOf("-n") != -1;

		if (!FileSystem.exists(hxml)) {
			Sys.println("File not found: " + hxml);
			Sys.exit(1);
		}

		
		var cpRoots:Map<String, Bool> = new Map();
		var visitedHxml:Map<String, Bool> = new Map();
		parseHxml(hxml, cpRoots, visitedHxml);
		var roots = [for (r in cpRoots.keys()) r];
		if (roots.length == 0) {
			Sys.println("No -cp entries found in " + hxml);
			return;
		}

		
		var allFiles = collectAllHxFiles(roots);

		
		var typeToPaths = buildTypeIndex(roots, allFiles);
		var uniqueMap:Map<String, String> = new Map();
		var ambiguous:StringSet = new StringSet();

		for (k in typeToPaths.keys()) {
			var arr = typeToPaths.get(k);
			
			var dedup = new Array<String>();
			var seen:Map<String, Bool> = new Map();
			for (p in arr)
				if (!seen.exists(p)) {
					seen.set(p, true);
					dedup.push(p);
				}
			if (dedup.length == 1)
				uniqueMap.set(k, dedup[0]);
			else
				ambiguous.add(k);
		}

		var uniqueCount = 0;
		for (_ in uniqueMap.keys()) uniqueCount++;
		Sys.println("Indexed ${allFiles.length} files, ${uniqueCount} unique types, ${ambiguous.size()} ambiguous type names.");

		
		var filesProcessed = 0;
		var filesChanged = 0;
		for (f in allFiles) {
			var res = fixImportsInFile(f, uniqueMap, dryRun);
			filesProcessed++;
			if (res.changed) {
				filesChanged++;
				for (m in res.messages)
					Sys.println((dryRun ? "[DRY]" : "[FIX]") + " " + f + " - " + m);
			}
		}
		Sys.println("Processed $filesProcessed files. " + (dryRun ? "Would change " : "Changed ") + filesChanged + " files.");
	}

	

	static function parseHxml(hxmlPath:String, cpSet:Map<String, Bool>, visited:Map<String, Bool>):Void {
		var abs = norm(FileSystem.fullPath(hxmlPath));
		if (visited.exists(abs))
			return;
		visited.set(abs, true);
		if (!FileSystem.exists(abs)) {
			Sys.println("Warning: .hxml not found: " + abs);
			return;
		}

		var content = File.getContent(abs);
		var tokens = tokenizeHxml(content);
		var baseDir = norm(Path.directory(abs));

		var i = 0;
		while (i < tokens.length) {
			var tok = tokens[i++];
			if (tok == null || tok.length == 0)
				continue;

			if (tok.charAt(0) == "@") {
				var inc = tok.substr(1);
				if (inc.length == 0) {
					if (i >= tokens.length) {
						warn(abs, "dangling '@'");
						break;
					}
					inc = tokens[i++];
				}
				var incPath = inc;
				if (!Path.isAbsolute(incPath))
					incPath = Path.normalize(Path.join([baseDir, incPath]));
				try
					parseHxml(incPath, cpSet, visited)
				catch (e:Dynamic)
					warn(abs, "include failed: " + incPath);
				continue;
			}

			if (tok == "-cp" || tok == "-p" || tok == "--class-path") {
				if (i >= tokens.length) {
					warn(abs, "missing path after " + tok);
					break;
				}
				var p = tokens[i++];
				var cp = p;
				if (!Path.isAbsolute(cp))
					cp = Path.normalize(Path.join([baseDir, cp]));
				try
					cp = norm(FileSystem.fullPath(cp))
				catch (_:Dynamic)
					cp = norm(cp);
				cpSet.set(cp, true);
				continue;
			}

			
			switch (tok) {
				case "-resource" | "-r" | "--resource" | "-lib" | "--library" | "-D" | "--define" | "-js" | "-hl" | "-neko" | "-php" | "-swf" | "-as3" |
					"-cpp" | "-cs" | "-java" | "-python" | "-lua" | "-main" | "-m" | "-cmd" | "-dce" | "-swf-version" | "-swf-header" | "-xml" | "-json" |
					"-hxml":
					if (i < tokens.length)
						i++;
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
		inline function flush() {
			var v = cur.toString();
			if (v.length > 0) {
				t.push(v);
				cur = new StringBuf();
			}
		}
		while (i < s.length) {
			var ch = s.charAt(i);
			if (!inQuote && ch == "#") { 
				flush();
				while (i < s.length && s.charAt(i) != "\n")
					i++;
				i++;
				continue;
			}
			if (!inQuote && isWS(ch)) {
				flush();
				i++;
				continue;
			}
			if (ch == "'" || ch == '"') {
				if (!inQuote) {
					inQuote = true;
					quote = ch;
					i++;
					continue;
				} else if (quote == ch) {
					inQuote = false;
					quote = "";
					i++;
					continue;
				} else {
					cur.add(ch);
					i++;
					continue;
				}
			}
			if (inQuote && ch == "\\") {
				if (i + 1 < s.length) {
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

	

	static function collectAllHxFiles(roots:Array<String>):Array<String> {
		var out = new Array<String>();
		var seen:Map<String, Bool> = new Map();
		for (r in roots) {
			if (!FileSystem.exists(r) || !FileSystem.isDirectory(r)) {
				Sys.println("Warning: classpath does not exist: " + r);
				continue;
			}
			var absRoot = norm(FileSystem.fullPath(r));
			walk(absRoot, out, seen);
		}
		return out;
	}

	static function walk(dir:String, out:Array<String>, seen:Map<String, Bool>):Void {
		var entries:Array<String>;
		try
			entries = FileSystem.readDirectory(dir)
		catch (_:Dynamic)
			return;
		for (name in entries) {
			if (name == "." || name == "..")
				continue;
			var p = dir + "/" + name;
			var isDir = false;
			try
				isDir = FileSystem.isDirectory(p)
			catch (_:Dynamic)
				continue;
			if (isDir) {
				walk(p, out, seen);
			} else {
				if (Path.extension(name).toLowerCase() == "hx") {
					var abs = norm(FileSystem.fullPath(p));
					if (!seen.exists(abs)) {
						seen.set(abs, true);
						out.push(abs);
					}
				}
			}
		}
	}

	
	static function buildTypeIndex(roots:Array<String>, files:Array<String>):Map<String, Array<String>> {
		
		var typeToPaths:Map<String, Array<String>> = new Map();

		for (f in files) {
			var root = pickBestRootForFile(f, roots);
			if (root == null)
				continue;

			var mod = moduleInfoFromPath(root, f);
			var content:String;
			try
				content = File.getContent(f)
			catch (_:Dynamic)
				continue;
			var typeNames = parseTopLevelTypeNames(content);

			mod.types = typeNames;

			
			for (t in mod.types) {
				var canonical = (t == mod.moduleName) ? mod.fullModule : mod.fullModule + "." + t;
				var arr = typeToPaths.get(t);
				if (arr == null) {
					arr = [];
					typeToPaths.set(t, arr);
				}
				arr.push(canonical);
			}
		}
		return typeToPaths;
	}

	static function pickBestRootForFile(fileAbs:String, roots:Array<String>):String {
		var best:String = null;
		var bestLen = -1;
		for (r in roots) {
			var rr = r;
			if (!rr.endsWith("/"))
				rr += "/";
			if (fileAbs.startsWith(rr)) {
				if (rr.length > bestLen) {
					best = r;
					bestLen = rr.length;
				}
			}
		}
		return best;
	}

	static function moduleInfoFromPath(root:String, fileAbs:String):ModuleInfo {
		var r = norm(FileSystem.fullPath(root));
		var f = norm(FileSystem.fullPath(fileAbs));
		if (!r.endsWith("/"))
			r += "/";
		var rel = f.startsWith(r) ? f.substr(r.length) : Path.withoutDirectory(f);
		var dir = Path.directory(rel);
		var pkg = (dir == null || dir == "" || dir == ".") ? "" : dir.split("\\").join("/").split("/").filter(x -> x != "").join(".");
		var moduleName = Path.withoutExtension(Path.withoutDirectory(rel));
		var fullModule = pkg == "" ? moduleName : (pkg + "." + moduleName);
		return {
			packagePath: pkg,
			moduleName: moduleName,
			fullModule: fullModule,
			types: []
		};
	}

	
	static function parseTopLevelTypeNames(s:String):Array<String> {
		var out = new Array<String>();
		var i = 0;
		var len = s.length;
		var depth = 0;
		var state = 0; 
		while (i < len) {
			var ch = s.charAt(i);

			
			if (state == 0) {
				
				if (ch == "/" && i + 1 < len) {
					var ch2 = s.charAt(i + 1);
					if (ch2 == "/") {
						state = 1;
						i += 2;
						continue;
					}
					if (ch2 == "*") {
						state = 2;
						i += 2;
						continue;
					}
				}
				
				if (ch == '"') {
					state = 3;
					i++;
					continue;
				}
				if (ch == "'") {
					state = 4;
					i++;
					continue;
				}

				
				if (ch == "{") {
					depth++;
					i++;
					continue;
				}
				if (ch == "}") {
					if (depth > 0)
						depth--;
					i++;
					continue;
				}

				if (depth == 0) {
					
					if (isWordStart(ch)) {
						var start = i;
						var id = readIdent(s, i);
						i += id.length;

						switch (id) {
							case "class", "interface":
								var name = readNameAfterKeyword(s, i);
								if (name != null)
									out.push(name);
							case "typedef":
								var name = readNameAfterKeyword(s, i);
								if (name != null)
									out.push(name);
							case "abstract":
								var name = readNameAfterKeyword(s, i);
								if (name != null)
									out.push(name);
							case "enum":
								
								var j = skipWS(s, i);
								if (matchWord(s, j, "abstract")) {
									j += "abstract".length;
									var name = readNameAfterKeyword(s, j);
									if (name != null)
										out.push(name);
								} else {
									var name = readNameAfterKeyword(s, i);
									if (name != null)
										out.push(name);
								}
							default:
						}
						continue;
					} else {
						i++;
						continue;
					}
				} else {
					i++;
					continue;
				}
			} else if (state == 1) { 
				if (ch == "\n") {
					state = 0;
				}
				i++;
			} else if (state == 2) { 
				if (ch == "*" && i + 1 < len && s.charAt(i + 1) == "/") {
					state = 0;
					i += 2;
				} else
					i++;
			} else if (state == 3) { 
				if (ch == "\\") {
					i += 2;
				} else if (ch == '"') {
					state = 0;
					i++;
				} else
					i++;
			} else if (state == 4) { 
				if (ch == "\\") {
					i += 2;
				} else if (ch == "'") {
					state = 0;
					i++;
				} else
					i++;
			}
		}
		
		var seen:Map<String, Bool> = new Map();
		var uniq = new Array<String>();
		for (t in out)
			if (!seen.exists(t)) {
				seen.set(t, true);
				uniq.push(t);
			}
		return uniq;
	}

	static function readNameAfterKeyword(s:String, pos:Int):Null<String> {
		var i = skipWS(s, pos);
		
		if (!isWordStartAt(s, i))
			return null;
		var name = readIdent(s, i);
		return name;
	}

	
	static function fixImportsInFile(filePath:String, uniqueMap:Map<String, String>, dryRun:Bool):FixResult {
		var content:String;
		try
			content = File.getContent(filePath)
		catch (_:Dynamic)
			return {changed: false, messages: []};
		var imports = findImports(content);

		var replacements:Array<{
			start:Int,
			end:Int,
			text:String,
			msg:String
		}> = [];
		for (imp in imports) {
			if (imp.hasWildcard)
				continue; 
			if (imp.pathSegments.length == 0)
				continue;
			var typeName = imp.pathSegments[imp.pathSegments.length - 1];

			var canonical = uniqueMap.get(typeName);
			if (canonical == null) {
				
				continue;
			}
			var currentPath = imp.pathSegments.join(".");
			
			if (currentPath == canonical)
				continue;

			var newImport = "import " + canonical + (imp.alias != null ? " as " + imp.alias : "") + ";";
			replacements.push({
				start: imp.start,
				end: imp.end,
				text: newImport,
				msg: 'import $currentPath -> $canonical'
			});
		}

		if (replacements.length == 0)
			return {changed: false, messages: []};

		
		replacements.sort(function(a, b) return a.start - b.start);
		var sb = new StringBuf();
		var last = 0;
		for (r in replacements) {
			sb.add(content.substring(last, r.start));
			sb.add(r.text);
			last = r.end;
		}
		sb.add(content.substring(last, content.length));
		var newContent = sb.toString();

		if (!dryRun)
			File.saveContent(filePath, newContent);
		var msgs = [for (r in replacements) r.msg];
		msgs.reverse(); 
		return {changed: true, messages: msgs};
	}

	static function reverseStringBuf(sb:StringBuf):String {
		
		var s = sb.toString();
		
		
		return s;
	}

	static function findImports(s:String):Array<ImportStmt> {
		var out = new Array<ImportStmt>();
		var i = 0;
		var len = s.length;
		var depth = 0;
		var state = 0; 
		while (i < len) {
			var ch = s.charAt(i);
			if (state == 0) {
				
				if (ch == "/" && i + 1 < len) {
					var ch2 = s.charAt(i + 1);
					if (ch2 == "/") {
						state = 1;
						i += 2;
						continue;
					}
					if (ch2 == "*") {
						state = 2;
						i += 2;
						continue;
					}
				}
				
				if (ch == '"') {
					state = 3;
					i++;
					continue;
				}
				if (ch == "'") {
					state = 4;
					i++;
					continue;
				}

				
				if (ch == "{") {
					depth++;
					i++;
					continue;
				}
				if (ch == "}") {
					if (depth > 0)
						depth--;
					i++;
					continue;
				}

				if (depth == 0 && isWordStart(ch) && matchWord(s, i, "import")) {
					var start = i;
					i += "import".length;
					var j = skipWS(s, i);

					
					var segments = new Array<String>();
					var hasWildcard = false;

					
					var stop = false;
					while (!stop) {
						j = skipWS(s, j);
						if (j >= len)
							break;
						var c = s.charAt(j);
						if (c == "*") {
							hasWildcard = true;
							j++;
							
							break;
						}
						if (!isWordStartAt(s, j)) {
							
							j = seekSemicolon(s, j);
							break;
						}
						var seg = readIdent(s, j);
						segments.push(seg);
						j += seg.length;

						j = skipWS(s, j);
						if (j < len && s.charAt(j) == ".") {
							j++;
							continue;
						} else {
							break;
						}
					}

					
					j = skipWS(s, j);
					var alias:Null<String> = null;
					if (matchWord(s, j, "as")) {
						j += "as".length;
						j = skipWS(s, j);
						if (isWordStartAt(s, j)) {
							var al = readIdent(s, j);
							alias = al;
							j += al.length;
						}
					}

					
					j = skipWS(s, j);
					j = seekSemicolon(s, j);
					var end = j < len ? j + 1 : len; 

					out.push({
						start: start,
						end: end,
						pathSegments: segments,
						hasWildcard: hasWildcard,
						alias: alias
					});
					i = end;
					continue;
				}

				i++;
			} else if (state == 1) { 
				if (ch == "\n")
					state = 0;
				i++;
			} else if (state == 2) { 
				if (ch == "*" && i + 1 < len && s.charAt(i + 1) == "/") {
					state = 0;
					i += 2;
				} else
					i++;
			} else if (state == 3) { 
				if (ch == "\\") {
					i += 2;
				} else if (ch == '"') {
					state = 0;
					i++;
				} else
					i++;
			} else if (state == 4) { 
				if (ch == "\\") {
					i += 2;
				} else if (ch == "'") {
					state = 0;
					i++;
				} else
					i++;
			}
		}
		return out;
	}

	

	static inline function isWS(ch:String):Bool
		return ch == " " || ch == "\t" || ch == "\r" || ch == "\n";

	static inline function isWordStart(ch:String):Bool
		return (ch >= "A" && ch <= "Z") || (ch >= "a" && ch <= "z") || ch == "_";

	static inline function isWordChar(ch:String):Bool
		return isWordStart(ch) || (ch >= "0" && ch <= "9");

	static inline function isWordStartAt(s:String, i:Int):Bool
		return i < s.length && isWordStart(s.charAt(i));

	static function readIdent(s:String, i:Int):String {
		var j = i;
		while (j < s.length) {
			var ch = s.charAt(j);
			if (!isWordChar(ch))
				break;
			j++;
		}
		return s.substring(i, j);
	}

	static function skipWS(s:String, i:Int):Int {
		var j = i;
		while (j < s.length && isWS(s.charAt(j)))
			j++;
		return j;
	}

	static function matchWord(s:String, i:Int, w:String):Bool {
		var L = w.length;
		if (i + L > s.length)
			return false;
		if (s.substr(i, L) != w)
			return false;
		var beforeOK = (i == 0) || !isWordChar(s.charAt(i - 1));
		var afterOK = (i + L >= s.length) || !isWordChar(s.charAt(i + L));
		return beforeOK && afterOK;
	}

	static function seekSemicolon(s:String, i:Int):Int {
		var j = i;
		var len = s.length;
		var state = 0; 
		while (j < len) {
			var ch = s.charAt(j);
			if (state == 0) {
				if (ch == ";")
					return j;
				if (ch == '"') {
					state = 3;
					j++;
					continue;
				}
				if (ch == "'") {
					state = 4;
					j++;
					continue;
				}
				if (ch == "/" && j + 1 < len) {
					var ch2 = s.charAt(j + 1);
					if (ch2 == "/") {
						state = 1;
						j += 2;
						continue;
					}
					if (ch2 == "*") {
						state = 2;
						j += 2;
						continue;
					}
				}
				j++;
			} else if (state == 1) {
				if (ch == "\n")
					state = 0;
				j++;
			} else if (state == 2) {
				if (ch == "*" && j + 1 < len && s.charAt(j + 1) == "/") {
					state = 0;
					j += 2;
				} else
					j++;
			} else if (state == 3) {
				if (ch == "\\") {
					j += 2;
				} else if (ch == '"') {
					state = 0;
					j++;
				} else
					j++;
			} else if (state == 4) {
				if (ch == "\\") {
					j += 2;
				} else if (ch == "'") {
					state = 0;
					j++;
				} else
					j++;
			}
		}
		return j;
	}

	static function norm(p:String):String
		return p.split("\\").join("/");

	static function warn(ctx:String, msg:String):Void
		Sys.println("Warning (" + ctx + "): " + msg);
}


class StringSet {
	var m:StringMap<Bool> = new StringMap<Bool>();

	public inline function new() {}

	public inline function add(v:String):Void
		m.set(v, true);

	public inline function has(v:String):Bool
		return m.exists(v);

	public inline function size():Int {
		var c = 0;
		var it = m.keys();
		while (it.hasNext()) { it.next(); c++; }
		return c;
	}
}
