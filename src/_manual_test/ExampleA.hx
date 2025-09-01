package _manual_test;

import haxe.ds.StringMap;
import haxe.io.Path as P;
import sys.io.File;

typedef Alias<T> = Array<T>;

enum abstract Status(Int) {
	var Ready;
	var Busy;
}

class Base {}

interface IRun {}

class ExampleA<T> extends Base implements IRun {
	public var m:Map<String, Int>;
	public var items:Alias<String>;

	public function new() {}

	public function go(fn:String->Status):Void {}
}

