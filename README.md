## haxe-projfix

You don't even need to install this, just copy-paste fix.hl into your project base dir.

Fixing packages and import statements after a refactor:

```
hl fix.hl fix-all path\to\build.hxml
```

Auto import all dependencies project-wide:

```
hl fix.hl auto-imports build.hxml
```

It goes without saying that you should probably first save a backup of your project or do a git commit. These scripts change the contents of the project files and do not have any built in rollback functionality.