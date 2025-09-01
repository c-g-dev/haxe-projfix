package;

import util.ModuleDiagnostics;
import sys.FileSystem;

class Diagnostics {
	public static function run(args:Array<String>) {
		if (args.length == 0 || args[0] == "-h" || args[0] == "--help") {
			Sys.println("Usage:");
			Sys.println("  haxe --run Main diagnose path/to/File.hx");
			return;
		}

		var path = args[0];
		if (!FileSystem.exists(path)) {
			Sys.println("File not found: " + path);
			Sys.exit(1);
		}

		var imports = ModuleDiagnostics.getImports(path);
		var deps = ModuleDiagnostics.getDependentTypes(path);

		Sys.println("Imports:");
		for (n in imports) Sys.println("  - " + n);
		Sys.println("");
		Sys.println("Dependent types:");
		for (n in deps) Sys.println("  - " + n);
	}
}

