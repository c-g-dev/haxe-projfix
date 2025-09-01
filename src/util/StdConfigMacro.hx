package util;

import haxe.macro.Expr;
using StringTools;
#if macro
import haxe.macro.Compiler;
import haxe.macro.Context;
import haxe.macro.Expr.ExprOf;

#end

class StdConfigMacro {
    public static macro function getStdRoots():ExprOf<Array<String>> {
#if macro
        var candidates = new Array<String>();

        var cfg:Dynamic = Compiler.getConfiguration();
        if (cfg != null) {
            for (name in ["stdPath", "std", "stdlibPath", "stdlib"]) {
                var v:Dynamic = Reflect.field(cfg, name);
                if (v == null) continue;
                if (Std.isOfType(v, String)) {
                    candidates.push(cast v);
                } else if (Std.isOfType(v, Array)) {
                    var arr:Array<Dynamic> = cast v;
                    for (x in arr) candidates.push(Std.string(x));
                }
            }
        }

        if (candidates.length == 0) {
            var cps = Context.getClassPath();
            for (cp in cps) {
                if (cp == null || cp.length == 0) continue;
                var norm = cp.split("\\").join("/");
                if (norm.endsWith("/")) norm = norm.substr(0, norm.length - 1);
                if (norm == "std" || norm.endsWith("/std")) candidates.push(cp);
            }
        }

        var seen:Map<String, Bool> = new Map();
        var out = new Array<String>();
        for (p in candidates) {
            var n = p.split("\\").join("/");
            if (!seen.exists(n)) { seen.set(n, true); out.push(n); }
        }

        var exprs = [for (p in out) macro $v{p}];
        return macro $a{exprs};
#else
        return macro [];
#end
    }
}


