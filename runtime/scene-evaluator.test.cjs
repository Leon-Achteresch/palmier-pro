const {readFileSync}=require("node:fs")
const vm=require("node:vm")
const test=require("node:test")
const assert=require("node:assert/strict")
const context=vm.createContext({})
vm.runInContext(readFileSync(`${__dirname}/scene-evaluator.js`,"utf8"),context)
const {evaluate,sample,multiply,inverse,matrix}=context.PalmierSceneEvaluation
const node=(id,properties={},extra={})=>({id,kind:"shape",startFrame:0,durationFrames:300,properties,props:{},tracks:[],recipes:[],hidden:false,locked:false,...extra})
const scene=nodes=>({revision:1,width:1920,height:1080,durationInFrames:300,fps:30,components:[],formats:[],nodes})

test("random-access frames equal sequential evaluation with recipes and repeated tracks",()=>{
  const document=scene([node("card",{}, {tracks:[{binding:"rotation",keys:[{frame:0,value:0,easing:{kind:"linear"}},{frame:30,value:90}],repeatCount:5,mirror:true,gapFrames:5}],recipes:[{kind:"slide-up-fade",startFrame:0,durationFrames:18,amount:40,repeatCount:1,easing:{kind:"easeOut"}}]})])
  const sequential=Array.from({length:300},(_,frame)=>JSON.stringify(evaluate(document,frame)))
  for(const frame of [0,200,20,200,299,18,0,299])assert.equal(JSON.stringify(evaluate(document,frame)),sequential[frame])
})

test("discrete props change at the exact keyframe",()=>{
  const track={keys:[{frame:0,value:"loading"},{frame:12,value:"ready"}]}
  assert.equal(sample(track,11,30),"loading")
  assert.equal(sample(track,12,30),"ready")
})

test("mirror repeats hold their endpoint during gaps and finish at the correct endpoint",()=>{
  const track={keys:[{frame:0,value:0,easing:{kind:"linear"}},{frame:10,value:100}],repeatCount:2,mirror:true,gapFrames:5}
  assert.equal(sample(track,12,30),100)
  assert.equal(sample(track,15,30),100)
  assert.equal(sample(track,20,30),50)
  assert.equal(sample(track,25,30),0)
  assert.equal(sample(track,200,30),0)
})

test("nested group transforms and camera affect stage bounds and inherited locks",()=>{
  const result=evaluate(scene([node("camera",{x:10,y:20},{kind:"camera"}),node("group",{x:100,y:50},{kind:"group",locked:true}),node("child",{x:5,y:6,width:20,height:10},{parentID:"group"})]),0)
  const child=result.nodes.find(n=>n.id==="child")
  assert.deepEqual(JSON.parse(JSON.stringify(child.bounds)),{x:95,y:36,width:20,height:10})
  assert.equal(child.locked,true)
})

test("inverse transforms preserve drag coordinates and reject singular transforms",()=>{
  const m=matrix({x:12,y:-8,width:100,height:50,anchorX:0.5,anchorY:0.5,rotation:37,scaleX:2,scaleY:0.7})
  const product=multiply(m,inverse(m))
  for(let i=0;i<6;i++)assert.ok(Math.abs(product[i]-[1,0,0,1,0,0][i])<1e-8)
  assert.equal(inverse([0,0,0,0,0,0]),null)
})

test("format overrides change layout without modifying the source scene",()=>{
  const document=scene([node("title",{x:100})])
  document.formats=[{id:"portrait",width:1080,height:1920,overrides:{title:{x:25}}}]
  assert.equal(evaluate(document,0,"portrait").nodes[0].properties.x,25)
  assert.equal(evaluate(document,0).nodes[0].properties.x,100)
  assert.equal(document.nodes[0].properties.x,100)
  assert.throws(()=>evaluate(document,0,"missing"))
})

test("non-finite and out-of-range frame requests are rejected",()=>{
  for(const frame of [-1,300,0.5,Infinity,NaN])assert.throws(()=>evaluate(scene([]),frame))
})
