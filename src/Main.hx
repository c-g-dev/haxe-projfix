
import Diagnostics;
import FixImports;
import FixPackages;
import StripComments;
import util.ProjectDiagnostics;


class Main {
	static public function main() {
		var args = Sys.args();
		var idx = findCommandIndex(args);
		if (idx == -1 || hasHelpFlag(args)) {
			printHelp();
			return;
		}

		var cmd = args[idx];
		var rest = args.slice(idx + 1);
		switch (cmd) {
			case "auto-imports":
				if (rest.length == 0) {
					printHelp();
					return;
				}
				var hxml = rest[0];
				var dryRun = rest.indexOf("--dry-run") != -1 || rest.indexOf("-n") != -1;
				//ProjectDiagnostics.autoImport(hxml, dryRun);
				util.ProjectDiagnostics.dumpStdResolvedTypeMap("build.hxml", "std-type-map.json");
			case "fix-imports":
				FixImports.run(rest);
			case "fix-packages":
				FixPackages.run(rest);
			case "strip-comments":
				StripComments.run(rest);
			case "diagnose":
				Diagnostics.run(rest);
			case "fix-all":
				
				FixPackages.run(rest);
				FixImports.run(rest);
			default:
				printHelp();
		}
	}

	static function hasHelpFlag(args:Array<String>):Bool {
		for (a in args) if (a == "-h" || a == "--help") return true;
		return false;
	}

	static function findCommandIndex(args:Array<String>):Int {
		for (i in 0...args.length) {
			var a = args[i];
			if (a == "auto-imports" || a == "fix-imports" || a == "fix-packages" || a == "strip-comments" || a == "diagnose" || a == "fix-all") return i;
		}
		return -1;
	}

	static function printHelp() {
		Sys.println("Usage:");
		Sys.println("  haxe --run Main <command> [args...]");
		Sys.println("");
		Sys.println("Commands:");
		Sys.println("  auto-imports  path/to/project.hxml [--dry-run|-n]");
		Sys.println("  fix-imports   path/to/project.hxml [--dry-run|-n]");
		Sys.println("  fix-packages  path/to/project.hxml [--dry-run|-n]");
		Sys.println("  strip-comments path/to/project.hxml [--dry-run|-n]");
		Sys.println("  diagnose      path/to/File.hx                # print imports and dependent types");
		Sys.println("  fix-all       path/to/project.hxml [--dry-run|-n]  # runs packages then imports");
	}
}


