package;

import sys.io.File;
import sys.FileSystem;
import haxe.io.Path;
import Map;
import Sys;


class StripComments {
	static public function main() {
		var args = Sys.args();
		run(args);
	}

	public static function run(args:Array<String>) {
		if (args.length == 0 || args[0] == "-h" || args[0] == "--help") {
			Sys.println("Usage:");
			Sys.println("  haxe --run StripComments path/to/project.hxml [--dry-run|-n]");
			return;
		}

		var hxml = args[0];
		var dryRun = args.indexOf("--dry-run") != -1 || args.indexOf("-n") != -1;

		if (!FileSystem.exists(hxml)) {
			Sys.println("File not found: " + hxml);
			Sys.exit(1);
		}

		var cpRoots:Map<String, Bool> = new Map();
		var visited:Map<String, Bool> = new Map();
		parseHxml(hxml, cpRoots, visited);

		var roots = [for (r in cpRoots.keys()) r];
		if (roots.length == 0) {
			Sys.println("No -cp entries found in " + hxml);
			return;
		}

		var files = collectAllHxFiles(roots);
		var processed = 0;
		var changed = 0;
		for (f in files) {
			var content = File.getContent(f);
			var stripped = stripComments(content);
			if (stripped != content) {
				if (!dryRun) File.saveContent(f, stripped);
				changed++;
				Sys.println((dryRun ? "[DRY]" : "[FIX]") + " " + f);
			}
			processed++;
		}
		Sys.println('Processed ' + processed + ' files. ' + (dryRun ? 'Would change ' : 'Changed ') + changed + ' files.');
	}

	static function parseHxml(hxmlPath:String, cpSet:Map<String, Bool>, visited:Map<String, Bool>):Void {
		var abs = norm(FileSystem.fullPath(hxmlPath));
		if (visited.exists(abs)) return;
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
			if (tok == null || tok.length == 0) continue;
			if (tok.charAt(0) == "@") {
				var inc = tok.substr(1);
				if (inc.length == 0) {
					if (i >= tokens.length) {
						Sys.println("Warning: '@' with no filename in " + abs);
						break;
					}
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
				cp = norm(FileSystem.fullPath(cp));
				cpSet.set(cp, true);
				continue;
			}
			
			switch (tok) {
				case "-resource" | "-r" | "--resource" | "-lib" | "--library" | "-D" | "--define" | "-js" | "-hl" | "-neko" | "-php" | "-swf" | "-as3" |
					"-cpp" | "-cs" | "-java" | "-python" | "-lua" | "-main" | "-m" | "-cmd" | "-dce" | "-swf-version" | "-swf-header" | "-xml" | "-json" |
					"-hxml":
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
				if (!inQuote) { inQuote = true; quote = ch; i++; continue; }
				else if (quote == ch) { inQuote = false; quote = ""; i++; continue; }
				else { cur.add(ch); i++; continue; }
			}
			if (inQuote && ch == "\\") {
				if (i + 1 < len) { i++; cur.add(s.charAt(i)); i++; continue; }
			}
			cur.add(ch);
			i++;
		}
		flush();
		return t;
	}

	static function collectAllHxFiles(roots:Array<String>):Array<String> {
		var out = new Array<String>();
		for (r in roots) {
			if (!FileSystem.exists(r) || !FileSystem.isDirectory(r)) {
				Sys.println("Warning: classpath does not exist: " + r);
				continue;
			}
			var absRoot = norm(FileSystem.fullPath(r));
			walk(absRoot, out);
		}
		return out;
	}

	static function walk(dir:String, out:Array<String>):Void {
		var entries = FileSystem.readDirectory(dir);
		for (name in entries) {
			if (name == "." || name == "..") continue;
			var p = dir + "/" + name;
			if (FileSystem.isDirectory(p)) {
				walk(p, out);
			} else {
				if (Path.extension(name).toLowerCase() == "hx") out.push(norm(FileSystem.fullPath(p)));
			}
		}
	}

	static function stripComments(s:String):String {
		var sb = new StringBuf();
		var i = 0;
		var len = s.length;
		var state = 0; 
		while (i < len) {
			var ch = s.charAt(i);
			if (state == 0) {
				if (ch == "/" && i + 1 < len) {
					var ch2 = s.charAt(i + 1);
					if (ch2 == "/") { state = 1; i += 2; continue; }
					if (ch2 == "*") { state = 2; i += 2; continue; }
				}
				if (ch == '"') { state = 3; sb.add(ch); i++; continue; }
				if (ch == "'") { state = 4; sb.add(ch); i++; continue; }
				sb.add(ch);
				i++;
			} else if (state == 1) { 
				if (ch == "\n") { sb.add(ch); state = 0; }
				i++;
			} else if (state == 2) { 
				if (ch == "*" && i + 1 < len && s.charAt(i + 1) == "/") { state = 0; i += 2; }
				else i++;
			} else if (state == 3) { 
				if (ch == "\\") { if (i + 1 < len) { sb.add(ch); sb.add(s.charAt(i + 1)); i += 2; continue; } }
				if (ch == '"') { sb.add(ch); i++; state = 0; continue; }
				sb.add(ch); i++;
			} else if (state == 4) { 
				if (ch == "\\") { if (i + 1 < len) { sb.add(ch); sb.add(s.charAt(i + 1)); i += 2; continue; } }
				if (ch == "'") { sb.add(ch); i++; state = 0; continue; }
				sb.add(ch); i++;
			}
		}
		return sb.toString();
	}

	static function norm(p:String):String
		return p.split("\\").join("/");
}


