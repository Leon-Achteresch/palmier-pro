(() => {
  const defaults = Object.freeze({
    x: 0, y: 0, width: 320, height: 180, scaleX: 1, scaleY: 1, rotation: 0,
    opacity: 1, anchorX: 0.5, anchorY: 0.5, cornerRadius: 0, blur: 0,
    fill: "#ffffff", stroke: "#000000", strokeWidth: 0, reveal: 1, text: "",
    fontSize: 48, fontFamily: "system-ui", fontWeight: 400, letterSpacing: 0,
    textAlign: "left", path: "", image: "", mask: "none", pathProgress: 1, textProgress: 1,
  })
  const clamp = (x, low = 0, high = 1) => Math.min(high, Math.max(low, x))
  const identity = () => [1, 0, 0, 1, 0, 0]
  const multiply = (a, b) => [
    a[0]*b[0]+a[2]*b[1], a[1]*b[0]+a[3]*b[1],
    a[0]*b[2]+a[2]*b[3], a[1]*b[2]+a[3]*b[3],
    a[0]*b[4]+a[2]*b[5]+a[4], a[1]*b[4]+a[3]*b[5]+a[5],
  ]
  const point = (m, x, y) => ({x: m[0]*x+m[2]*y+m[4], y: m[1]*x+m[3]*y+m[5]})
  function inverse(m) {
    const determinant = m[0]*m[3]-m[1]*m[2]
    if (Math.abs(determinant) < 1e-10) return null
    return [m[3]/determinant, -m[1]/determinant, -m[2]/determinant, m[0]/determinant,
      (m[2]*m[5]-m[3]*m[4])/determinant, (m[1]*m[4]-m[0]*m[5])/determinant]
  }
  function matrix(p) {
    const r = p.rotation*Math.PI/180, c = Math.cos(r), s = Math.sin(r)
    const a = c*p.scaleX, b = s*p.scaleX, d = c*p.scaleY, e = -s*p.scaleY
    const ax = p.width*p.anchorX, ay = p.height*p.anchorY
    return [a,b,e,d,p.x+ax-a*ax-e*ay,p.y+ay-b*ax-d*ay]
  }
  function cubic(t, p1, p2) { return 3*(1-t)*(1-t)*t*p1+3*(1-t)*t*t*p2+t*t*t }
  function ease(t, config = {}, seconds = 1) {
    t = clamp(t)
    if (t === 0 || t === 1) return t
    switch (config.kind) {
      case "hold": return 0
      case "linear": return t
      case "easeIn": return t*t*t
      case "easeInOut": return t < 0.5 ? 4*t*t*t : 1-Math.pow(-2*t+2,3)/2
      case "bezier": {
        let lo=0, hi=1, u=t
        for(let i=0;i<28;i++) {
          if(cubic(u,config.x1,config.x2)<t)lo=u;else hi=u
          u=(lo+hi)/2
        }
        return cubic(u,config.y1,config.y2)
      }
      case "spring": {
        const k=config.stiffness ?? 170, damping=config.damping ?? 26, mass=config.mass ?? 1
        const w=Math.sqrt(k/mass), z=damping/(2*Math.sqrt(k*mass)), time=t*seconds
        if(z<1-1e-6) {
          const wd=w*Math.sqrt(1-z*z)
          return 1-Math.exp(-z*w*time)*(Math.cos(wd*time)+(z*w/wd)*Math.sin(wd*time))
        }
        if(z>1+1e-6) {
          const root=Math.sqrt(z*z-1), r1=-w*(z-root), r2=-w*(z+root)
          return 1-(r2*Math.exp(r1*time)-r1*Math.exp(r2*time))/(r2-r1)
        }
        return 1-Math.exp(-w*time)*(1+w*time)
      }
      default: return 1-Math.pow(1-t,3)
    }
  }
  function cycle(frame, start, duration, count=1, mirror=false, gap=0) {
    const elapsed=Math.max(0,frame-start), period=duration+gap
    const index=Math.min(count-1,Math.floor(elapsed/period))
    let progress=clamp((elapsed-index*period)/duration)
    if(mirror && index%2===1)progress=1-progress
    return progress
  }
  function sample(track, frame, fps) {
    const keys=track.keys, first=keys[0], last=keys[keys.length-1]
    if(keys.length===1)return first.value
    if((track.repeatCount ?? 1)>1 && frame>=first.frame) {
      frame=first.frame+cycle(frame,first.frame,last.frame-first.frame,track.repeatCount,track.mirror,track.gapFrames)*(last.frame-first.frame)
    }
    if(frame<=first.frame)return first.value
    if(frame>=last.frame)return last.value
    let lo=0,hi=keys.length-1
    while(lo+1<hi) {const mid=(lo+hi)>>1;if(keys[mid].frame<=frame)lo=mid;else hi=mid}
    const a=keys[lo],b=keys[hi]
    if(typeof a.value!=="number" || typeof b.value!=="number")return a.value
    return a.value+(b.value-a.value)*ease((frame-a.frame)/(b.frame-a.frame),a.easing,(b.frame-a.frame)/fps)
  }
  function recipe(p, recipe, frame, fps) {
    const progress=cycle(frame,recipe.startFrame,recipe.durationFrames,recipe.repeatCount,recipe.mirror,recipe.gapFrames)
    const t=ease(progress,recipe.easing,recipe.durationFrames/fps), amount=recipe.amount
    switch(recipe.kind) {
      case "slide-up-fade": p.y+=amount*(1-t);p.opacity*=clamp(t);break
      case "slide-left-fade": p.x-=amount*(1-t);p.opacity*=clamp(t);break
      case "pop": p.scaleX*=0.6+0.4*t;p.scaleY*=0.6+0.4*t;p.opacity*=clamp(t);break
      case "fade-in": p.opacity*=clamp(t);break
      case "fade-out": p.opacity*=1-clamp(t);break
      case "float": if(frame>=recipe.startFrame)p.y-=amount*Math.sin(progress*Math.PI*2);break
      case "pulse": if(frame>=recipe.startFrame){const s=1+(amount/100)*Math.sin(progress*Math.PI*2);p.scaleX*=s;p.scaleY*=s}break
      case "spin": p.rotation+=amount*t;break
      case "typewriter": p.text=Array.from(p.text).slice(0,Math.floor(Array.from(p.text).length*clamp(t))).join("");break
      case "text-stagger": p.textProgress=clamp(t);break
    }
  }
  function bounded(p) {
    p.opacity=clamp(p.opacity);p.reveal=clamp(p.reveal);p.pathProgress=clamp(p.pathProgress)
    p.width=Math.max(0,p.width);p.height=Math.max(0,p.height);p.blur=Math.max(0,p.blur)
    p.cornerRadius=Math.max(0,p.cornerRadius);p.strokeWidth=Math.max(0,p.strokeWidth)
    return p
  }
  function evaluate(document, frame, formatID=null) {
    if(!Number.isSafeInteger(frame)||frame<0||frame>=document.durationInFrames)throw new Error("frame is outside the scene")
    const format=formatID ? document.formats.find(x=>x.id===formatID) : null
    if(formatID&&!format)throw new Error("unknown format")
    const width=format?.width ?? document.width,height=format?.height ?? document.height
    const components=new Map(document.components.map(c=>[c.id,c]))
    const states=new Map()
    for(const node of document.nodes) {
      const component=components.get(node.componentID)
      const p={...defaults,...node.properties,...(format?.overrides[node.id] ?? {})}
      const props=Object.fromEntries((component?.props ?? []).map(x=>[x.id,x.defaultValue]))
      Object.assign(props,node.props)
      const slots={},localFrame=frame-node.startFrame
      for(const track of node.tracks) {
        const value=sample(track,localFrame,document.fps)
        if(track.binding.startsWith("props."))props[track.binding.slice(6)]=value
        else if(track.binding.startsWith("slots.")) {
          const [,slot,key]=track.binding.split(".");(slots[slot]??={})[key]=value
        } else p[track.binding]=value
      }
      const animatedProperties={...p}
      for(const r of node.recipes)recipe(p,r,localFrame,document.fps)
      bounded(p)
      states.set(node.id,{id:node.id,kind:node.kind,parentID:node.parentID ?? null,properties:p,animatedProperties,props,slots,
        active:!node.hidden&&localFrame>=0&&localFrame<node.durationFrames,locked:node.locked,localFrame,
        matrix:matrix(p),worldMatrix:null,parentMatrix:null,inverseParentMatrix:null,bounds:null})
    }
    let camera=identity()
    const cameraState=[...states.values()].find(s=>s.kind==="camera"&&s.active)
    if(cameraState)camera=inverse(cameraState.matrix) ?? identity()
    function world(state) {
      if(state.worldMatrix)return
      const parent=states.get(state.parentID)
      if(parent)world(parent)
      state.active=state.active&&(!parent||parent.active)
      state.locked=state.locked||!!parent?.locked
      state.parentMatrix=parent?.worldMatrix ?? (state.kind==="camera"?identity():camera)
      state.inverseParentMatrix=inverse(state.parentMatrix)
      state.worldMatrix=multiply(state.parentMatrix,state.matrix)
      const p=state.properties,corners=[[0,0],[p.width,0],[p.width,p.height],[0,p.height]].map(([x,y])=>point(state.worldMatrix,x,y))
      const xs=corners.map(p=>p.x),ys=corners.map(p=>p.y)
      state.bounds={x:Math.min(...xs),y:Math.min(...ys),width:Math.max(...xs)-Math.min(...xs),height:Math.max(...ys)-Math.min(...ys)}
    }
    for(const state of states.values())world(state)
    return {frame,revision:document.revision,width,height,camera,nodes:[...states.values()]}
  }
  globalThis.PalmierSceneEvaluation=Object.freeze({evaluate,sample,ease,cycle,matrix,multiply,inverse,point,defaults})
})()
