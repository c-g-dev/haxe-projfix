package util;

import sys.io.File;
import haxe.ds.StringMap;
import haxeparser.Data;
import haxeparser.HaxeParser;
import byte.ByteData;
import Map;
import Reflect;

// Avoid importing haxe.macro.Expr to prevent AbstractFlag name conflicts

private typedef Module = {
	pack:Array<String>,
	decls:Array<haxeparser.Data.TypeDecl>
}

class ModuleDiagnostics {
	public static var cachedFiles:Map<String, ModuleDiagnosticsFile> = new Map();

	static final BUILTIN_TYPES:Array<String> = [
		"Int","Float","Bool","String","Void","Dynamic","Null","Array","Class","Enum","Iterator","Iterable","EReg","Date"
	];

	public static function getModuleLevelFields(path:String):Array<String> {
		var f = ensure(path);
		if (!f.didSuccessfullyParse) return [];
		var mod = f.module;
		if (mod == null) return [];
		var out = new Array<String>();
		for (td in mod.decls) {
			switch (td.decl) {
				case EClass(d): out.push(d.name);
				case EEnum(d): out.push(d.name);
				case ETypedef(d): out.push(d.name);
				case EAbstract(a): out.push(a.name);
				case EImport(_, _):
				case EUsing(_):
				case EStatic(_):
			}
		}
		return unique(out);
	}

	public static function getImports(path:String):Array<String> {
		var f = ensure(path);
		if (!f.didSuccessfullyParse) return [];
		var mod = f.module;
		if (mod == null) return [];
		var names = new Array<String>();
		for (td in mod.decls) {
			switch (td.decl) {
				case EImport(sl, mode):
					var lastSeg = sl.length > 0 ? sl[sl.length - 1].pack : null;
					switch (mode) {
						case INormal:
							if (lastSeg != null) names.push(lastSeg);
						case IAsName(alias):
							if (lastSeg != null) names.push(lastSeg);
						case IAll:
					}
				case _:
			}
		}
		return unique(names);
	}

	public static function getDependentTypes(path:String):Array<String> {
		var f = ensure(path);
		if (!f.didSuccessfullyParse) return [];
		var mod = f.module;
		if (mod == null) return [];

		var needed = new StringMap<Bool>();
		var topTypes = new StringMap<Bool>();
		var imported = new StringMap<Bool>();
		for (name in getModuleLevelFields(path)) topTypes.set(name, true);
		for (name in getImports(path)) imported.set(name, true);
		var builtins = new StringMap<Bool>();
		for (b in BUILTIN_TYPES) builtins.set(b, true);
		var staticTypes = new StringMap<Bool>();

		for (td in mod.decls) {
			switch (td.decl) {
				case EClass(d):
					collectTypeParams(d.params, needed, []);
					for (flag in d.flags) switch (flag) {
						case HExtends(t): collectTypePath(t, needed, []);
						case HImplements(t): collectTypePath(t, needed, []);
						case _:
					}
					for (fld in d.data) visitField(fld, needed, [], staticTypes);
				case EEnum(d):
					for (ctor in d.data) {
						for (a in ctor.args) if (a.type != null) collectComplexType(a.type, needed, []);
						if (ctor.type != null) collectComplexType(ctor.type, needed, []);
					}
				case ETypedef(d):
					collectTypeParams(d.params, needed, []);
					if (d.data != null) collectComplexType(d.data, needed, []);
				case EAbstract(a):
					collectTypeParams(a.params, needed, []);
					for (fld in a.data) visitField(fld, needed, [], staticTypes);
				case EImport(_, _):
				case EUsing(_):
				case EStatic(_):
			}
		}

		var out = new Array<String>();
		var it = needed.keys();
		while (it.hasNext()) {
			var n = it.next();
			if (!topTypes.exists(n) && !imported.exists(n) && !builtins.exists(n)) out.push(n);
		}
		// Always include static type references, even if imported
		var st = staticTypes.keys();
		while (st.hasNext()) {
			var n = st.next();
			if (!builtins.exists(n)) out.push(n);
		}
		out.sort(Reflect.compare);
		return unique(out);
	}

	static function ensure(path:String):ModuleDiagnosticsFile {
		var abs = path;
		if (cachedFiles.exists(abs)) return cachedFiles.get(abs);
		var f = new ModuleDiagnosticsFile(abs);
		cachedFiles.set(abs, f);
		return f;
	}

	static function visitField(f:haxe.macro.Expr.Field, needed:StringMap<Bool>, tpScope:Array<String>, staticTypes:StringMap<Bool>):Void {
		switch (f.kind) {
			case FVar(t, _):
				if (t != null) collectComplexType(t, needed, tpScope);
			case FProp(_, _, t, _):
				if (t != null) collectComplexType(t, needed, tpScope);
			case FFun(fn):
				collectFunction(fn, needed, tpScope, [], staticTypes);
		}
	}

	static function collectFunction(fn:haxe.macro.Expr.Function, needed:StringMap<Bool>, parentScope:Array<String>, parentVarScope:Array<String>, staticTypes:StringMap<Bool>):Void {
		var scope = parentScope.copy();
		collectTypeParams(fn.params, needed, scope);
		var varScope = parentVarScope.copy();
		for (a in fn.args) {
			if (a.type != null) collectComplexType(a.type, needed, scope);
			varScope.push(a.name);
		}
		if (fn.ret != null) collectComplexType(fn.ret, needed, scope);
		if (fn.expr != null) visitExprScoped(fn.expr, needed, scope, varScope, staticTypes);
	}

	static function visitExpr(e:haxe.macro.Expr.Expr, needed:StringMap<Bool>, tpScope:Array<String>, staticTypes:StringMap<Bool>):Void {
		if (e == null) return;
        if(e.expr == null) return;
		visitExprScoped(e, needed, tpScope, [], staticTypes);
	}

	static function visitExprScoped(e:haxe.macro.Expr.Expr, needed:StringMap<Bool>, tpScope:Array<String>, varScope:Array<String>, staticTypes:StringMap<Bool>):Void {
		if (e == null) return;
		if (e.expr == null) return;
		switch (e.expr) {
			case EBlock(exprs):
				for (ee in exprs) visitExprScoped(ee, needed, tpScope, varScope, staticTypes);
			case EVars(vars):
				for (v in vars) varScope.push(v.name);
				for (v in vars) if (v.type != null) collectComplexType(v.type, needed, tpScope);
				for (v in vars) if (v.expr != null) visitExprScoped(v.expr, needed, tpScope, varScope, staticTypes);
			case ECall(callee, args):
				visitExprScoped(callee, needed, tpScope, varScope, staticTypes);
				for (a in args) visitExprScoped(a, needed, tpScope, varScope, staticTypes);
			case EArray(e1, e2):
				visitExprScoped(e1, needed, tpScope, varScope, staticTypes);
				visitExprScoped(e2, needed, tpScope, varScope, staticTypes);
			case EBinop(_, e1, e2):
				visitExprScoped(e1, needed, tpScope, varScope, staticTypes);
				visitExprScoped(e2, needed, tpScope, varScope, staticTypes);
			case EUnop(_, _, e1):
				visitExprScoped(e1, needed, tpScope, varScope, staticTypes);
			case EIf(cond, eThen, eElse):
				visitExprScoped(cond, needed, tpScope, varScope, staticTypes);
				visitExprScoped(eThen, needed, tpScope, varScope, staticTypes);
				if (eElse != null) visitExprScoped(eElse, needed, tpScope, varScope, staticTypes);
			case EWhile(cond, body, _):
				visitExprScoped(cond, needed, tpScope, varScope, staticTypes);
				visitExprScoped(body, needed, tpScope, varScope, staticTypes);
			case EFor(_, body):
				visitExprScoped(body, needed, tpScope, varScope, staticTypes);
			case ESwitch(e1, cases, def):
				visitExprScoped(e1, needed, tpScope, varScope, staticTypes);
				for (c in cases) {
					for (ee in c.values) visitExprScoped(ee, needed, tpScope, varScope, staticTypes);
					visitExprScoped(c.expr, needed, tpScope, varScope, staticTypes);
				}
				if (def != null) visitExprScoped(def, needed, tpScope, varScope, staticTypes);
			case EFunction(_, fn):
				collectFunction(fn, needed, tpScope, varScope, staticTypes);
			case ECheckType(e1, t):
				collectComplexType(t, needed, tpScope);
				visitExprScoped(e1, needed, tpScope, varScope, staticTypes);
			case EField(target, field, _):
				// Capture static field references like TypeName.field but only record the type name
				// and filter out local variable field access using the current var scope.
				switch (target.expr) {
					case EConst(c):
						switch (c) {
							case CIdent(name):
								if (!isVarInScope(name, varScope)) staticTypes.set(name, true);
							case _:
						}
					case _:
				}
				visitExprScoped(target, needed, tpScope, varScope, staticTypes);
			case EObjectDecl(fields):
				for (f in fields) visitExprScoped(f.expr, needed, tpScope, varScope, staticTypes);
			case EArrayDecl(elts):
				for (ee in elts) visitExprScoped(ee, needed, tpScope, varScope, staticTypes);
			case EReturn(e1):
				if (e1 != null) visitExprScoped(e1, needed, tpScope, varScope, staticTypes);
			case EParenthesis(e1):
				visitExprScoped(e1, needed, tpScope, varScope, staticTypes);
			case ENew(_, args):
				for (a in args) visitExprScoped(a, needed, tpScope, varScope, staticTypes);
			case EThrow(e1):
				visitExprScoped(e1, needed, tpScope, varScope, staticTypes);
			case ETernary(econd, eif, eelse):
				visitExprScoped(econd, needed, tpScope, varScope, staticTypes);
				visitExprScoped(eif, needed, tpScope, varScope, staticTypes);
				visitExprScoped(eelse, needed, tpScope, varScope, staticTypes);
			case ECast(e1, _):
				visitExprScoped(e1, needed, tpScope, varScope, staticTypes);
			case ETry(tryExpr, catches):
				visitExprScoped(tryExpr, needed, tpScope, varScope, staticTypes);
				for (c in catches) {
					if (c.type != null) collectComplexType(c.type, needed, tpScope);
					visitExprScoped(c.expr, needed, tpScope, varScope, staticTypes);
				}
			case EMeta(_, inner):
				visitExprScoped(inner, needed, tpScope, varScope, staticTypes);
			default:
				// no recursive walk needed beyond handled cases for type hints
		}
	}

	static function collectTypeParams(params:Array<haxe.macro.Expr.TypeParamDecl>, needed:StringMap<Bool>, tpScope:Array<String>):Void {
		if (params == null) return;
		for (p in params) {
			tpScope.push(p.name);
			if (p.constraints != null)
				for (c in p.constraints) collectComplexType(c, needed, tpScope);
			if (p.defaultType != null) collectComplexType(p.defaultType, needed, tpScope);
			if (p.params != null) collectTypeParams(p.params, needed, tpScope);
		}
	}

	static function collectTypePath(tp:haxe.macro.Expr.TypePath, needed:StringMap<Bool>, tpScope:Array<String>):Void {
		if (tp.pack == null || tp.pack.length == 0) {
			if (!isTypeParam(tp.name, tpScope)) needed.set(tp.name, true);
		}
		if (tp.params != null) {
			for (p in tp.params) switch (p) {
				case TPType(ct): collectComplexType(ct, needed, tpScope);
				case TPExpr(_):
			}
		}
	}

	static function collectComplexType(t:haxe.macro.Expr.ComplexType, needed:StringMap<Bool>, tpScope:Array<String>):Void {
		switch (t) {
			case TPath(tp):
				collectTypePath(tp, needed, tpScope);
			case TFunction(args, ret):
				for (a in args) collectComplexType(a, needed, tpScope);
				collectComplexType(ret, needed, tpScope);
			case TAnonymous(fields):
				for (f in fields) visitField(f, needed, tpScope, new StringMap());
			case TParent(t1) | TOptional(t1) | TNamed(_, t1):
				collectComplexType(t1, needed, tpScope);
			case TExtend(paths, fields):
				for (p in paths) collectTypePath(p, needed, tpScope);
				for (f in fields) visitField(f, needed, tpScope, new StringMap());
			case TIntersection(ts):
				for (t1 in ts) collectComplexType(t1, needed, tpScope);
		}
	}

	static function isTypeParam(name:String, tpScope:Array<String>):Bool {
		for (n in tpScope) if (n == name) return true;
		return false;
	}

	static inline function unique(arr:Array<String>):Array<String> {
		var m = new StringMap<Bool>();
		var out = new Array<String>();
		for (n in arr) if (!m.exists(n)) { m.set(n, true); out.push(n); }
		return out;
	}

	static function isVarInScope(name:String, varScope:Array<String>):Bool {
		for (n in varScope) if (n == name) return true;
		return false;
	}
}

class ModuleDiagnosticsFile {
	public var path:String;
	public var content:String;
	public var module:Module;
    public var didSuccessfullyParse:Bool = false;

	public function new(path:String) {
		this.path = path;
		this.content = File.getContent(path);
		var parser = new HaxeParser(ByteData.ofString(this.content), path);
		try {
			var parsed = parser.parse();
			this.module = cast parsed;
			this.didSuccessfullyParse = true;
		} catch (e:Dynamic) {
			this.didSuccessfullyParse = false;
		}
	}
}