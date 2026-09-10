const test = require("node:test")
const assert = require("node:assert/strict")
const {readFileSync} = require("node:fs")
const module_ = import(`data:text/javascript;base64,${readFileSync(`${__dirname}/image-source.js`).toString("base64")}`)

test("bundled require image strings become native image sources", async () => {
  const {embeddedImageSource} = await module_
  assert.deepEqual(embeddedImageSource("data:image/png;base64,abc"), {uri:"data:image/png;base64,abc"})
})

test("empty images have no pending resource", async () => {
  const {embeddedImageSource} = await module_
  for (const input of [null, undefined, []]) assert.equal(embeddedImageSource(input), null)
})

test("unpinned images and asset registry IDs are refused", async () => {
  const {embeddedImageSource} = await module_
  for (const input of [1, {}, "https://example.com/image.png", {uri:"file:///image.png"}, [{uri:"https://example.com/image.png"}]]) {
    assert.throws(() => embeddedImageSource(input), /embedded data URLs/)
  }
})

test("native image metadata survives normalization", async () => {
  const {embeddedImageSource} = await module_
  const source = {uri:"data:image/png;base64,abc",width:20,height:20,scale:2}
  assert.deepEqual(embeddedImageSource([source]), [source])
})

test("invalid image candidate lists are refused", async () => {
  const {embeddedImageSource} = await module_
  for (const input of [[null], [[]], Array(17).fill("data:image/png;base64,abc")]) assert.throws(() => embeddedImageSource(input), /1 to 16/)
})
