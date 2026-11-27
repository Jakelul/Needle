const assert = require("node:assert/strict");
const Queue = require("../Sources/Needle/Resources/Player.js");
const q = new Queue(["a","b","c"]);
q.repeat = "one";
assert(q.ended()); assert.equal(q.current,"a");
q.step(1); assert.equal(q.current,"b"); // Manual next still works in repeat-one.
q.repeat = "off"; q.step(1);
assert.equal(q.ended(),false); assert.equal(q.current,"c");
q.repeat = "all"; assert(q.ended()); assert.equal(q.current,"a");
q.shuffle(true,() => 0); assert.equal(q.current,"a");
const shuffled = q.items.slice();
assert.equal(q.sync(["a","b","c"]),false);
assert.deepEqual(q.items,shuffled); assert(q.shuffled);
q.sync(["a","b","c","d"]); assert(q.shuffled); assert.equal(q.current,"a");
assert(q.items.includes("d"));
q.shuffle(false); assert.deepEqual(q.items,["a","b","c","d"]);
q.move(0,2); assert.equal(q.index,2); assert.equal(q.current,"a");
q.sync(["a","b","c","d"]); assert.equal(q.index,2); // Unchanged remote must not undo a drag.
q.sync(["b","d"]); assert.equal(q.current,"b"); // Removed current switches to a valid track.
const duplicate = new Queue(["a","b","a"]); duplicate.index = 2;
duplicate.move(2,0); assert.equal(duplicate.index,0);
console.log("Playback checks passed: repeat modes, manual next, shuffle, sync and reorder.");
