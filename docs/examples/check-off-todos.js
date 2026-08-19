// SwiftMind L3 sample script.
// Checks off every node whose title or note contains "todo".
// Run from the command palette: ⌘K → "Run Script…" → pick this file.
// Everything the script does is applied as ONE undoable step (⌘Z).

var ids = mindmap.find("todo");
ids.forEach(function (id) {
    mindmap.addIcon(id, "check");
    mindmap.setAttr(id, "status", "done");
});
mindmap.log("checked off " + ids.length + " node(s)");
