package;

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
			case "fix-imports":
				FixImports.run(rest);
			case "fix-packages":
				FixPackages.run(rest);
			case "strip-comments":
				StripComments.run(rest);
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
			if (a == "fix-imports" || a == "fix-packages" || a == "strip-comments" || a == "fix-all") return i;
		}
		return -1;
	}

	static function printHelp() {
		Sys.println("Usage:");
		Sys.println("  haxe --run Main <command> [args...]");
		Sys.println("");
		Sys.println("Commands:");
		Sys.println("  fix-imports   path/to/project.hxml [--dry-run|-n]");
		Sys.println("  fix-packages  path/to/project.hxml [--dry-run|-n]");
		Sys.println("  strip-comments path/to/project.hxml [--dry-run|-n]");
		Sys.println("  fix-all       path/to/project.hxml [--dry-run|-n]  # runs packages then imports");
	}
}


