import React from "react"
import "./scene-evaluator.js"

export function createSceneRenderer({View, Text, Image, native, Shape, Mask, pathCommands, evaluateComponent, useCurrentFrame, ConfigContext, TimelineContext}) {
  const componentCache=new Map()
  let cachedBytes=0
  function compile(component) {
    const cached=componentCache.get(component.source)
    if(cached)return cached
    const result=evaluateComponent(component.source)
    componentCache.set(component.source,result)
    cachedBytes+=component.source.length*2
    while(cachedBytes>32*1024*1024||componentCache.size>128) {
      const oldest=componentCache.keys().next().value
      cachedBytes-=oldest.length*2;componentCache.delete(oldest)
    }
    return result
  }
  const SlotContext=React.createContext({values:{},nodeID:""})
  const FrameEpochContext=React.createContext(0)
  const transform = p => native
    ? [{translateX:p.x ?? 0},{translateY:p.y ?? 0},{rotate:`${p.rotation ?? 0}deg`},{scaleX:p.scaleX ?? 1},{scaleY:p.scaleY ?? 1}]
    : `translate(${p.x ?? 0}px,${p.y ?? 0}px) rotate(${p.rotation ?? 0}deg) scale(${p.scaleX ?? 1},${p.scaleY ?? 1})`
  function MotionSlot({id,itemKey,children,style,...rest}) {
    const context=React.useContext(SlotContext),slotID=itemKey===undefined?id:`${id}:${itemKey}`,p=context.values[slotID]
    const animated=p ? {transform:transform(p),opacity:p.opacity ?? 1,...(!native&&p.reveal!==undefined?{clipPath:`inset(0 ${(1-p.reveal)*100}% 0 0)`}:{})} : {}
    if(native)return React.createElement(View,{...rest,collapsable:false,style:[style,animated]},
      React.createElement(Mask,{pointerEvents:"none",style:{position:"absolute",left:0,top:0,width:0,height:0},motionSlotID:slotID,motionNodeID:context.nodeID,motionReveal:p?.reveal ?? 1}),children)
    return React.createElement(View,{...rest,"data-motion-slot":slotID,"data-motion-owner":context.nodeID,style:{...style,...animated}},children)
  }
  function alphaColor(color, opacity) {
    if(color==="transparent")return color
    let hex=color.slice(1)
    if(hex.length<=4)hex=Array.from(hex).map(x=>x+x).join("")
    const alpha=hex.length===8?parseInt(hex.slice(6),16):255
    return `#${hex.slice(0,6)}${Math.round(alpha*opacity).toString(16).padStart(2,"0")}`
  }
  function SceneDocument({document}) {
    const frame=useCurrentFrame()
    const epoch=React.useContext(FrameEpochContext)
    const evaluated=globalThis.PalmierSceneEvaluation.evaluate(document,frame)
    const compiled=React.useMemo(()=>new Map(document.components.map(c=>[c.id,compile(c)])),[document.components])
    const stateMap=new Map(evaluated.nodes.map(n=>[n.id,n]))
    const children=new Map()
    for(const node of document.nodes) {const parent=node.parentID ?? null;if(!children.has(parent))children.set(parent,[]);children.get(parent).push(node)}
    function renderNode(node) {
      const state=stateMap.get(node.id),p=state.properties
      if(!state.active||node.kind==="camera")return null
      const style={position:"absolute",left:p.x,top:p.y,width:p.width,height:p.height,opacity:p.opacity,
        transform:native?[{rotate:`${p.rotation}deg`},{scaleX:p.scaleX},{scaleY:p.scaleY}]:`rotate(${p.rotation}deg) scale(${p.scaleX},${p.scaleY})`,
        transformOrigin:native?[p.width*p.anchorX,p.height*p.anchorY,0]:`${p.anchorX*100}% ${p.anchorY*100}%`,
        ...(!native?{borderRadius:p.cornerRadius,overflow:p.mask!=="none"?"hidden":"visible",filter:p.blur>0?`blur(${p.blur}px)`:undefined,clipPath:p.reveal<1?`inset(0 ${(1-p.reveal)*100}% 0 0)`:undefined,maskImage:p.mask==="ellipse"?"radial-gradient(ellipse 50% 50% at 50% 50%, #000 99%, transparent 100%)":undefined}:{}),
      }
      let content
      switch(node.kind) {
        case "component": {
          const Component=compiled.get(node.componentID)
          content=React.createElement(SlotContext.Provider,{value:{values:state.slots,nodeID:node.id}},React.createElement(Component,{...state.props,key:`${state.localFrame}:${epoch}`}))
          break
        }
        case "text": {
          const textStyle={color:p.fill,fontSize:p.fontSize,fontFamily:p.fontFamily,fontWeight:String(p.fontWeight),letterSpacing:p.letterSpacing,textAlign:p.textAlign,...(!native?{display:"block",width:"100%",whiteSpace:"pre-wrap",margin:0}:{})}
          if(p.textProgress!==undefined) {
            const letters=Array.from(p.text)
            content=React.createElement(Text,{style:textStyle},letters.map((letter,i)=>React.createElement(Text,{key:i,style:native?{color:alphaColor(p.fill,Math.min(1,Math.max(0,p.textProgress*(letters.length+3)-i)/3))}:{opacity:Math.min(1,Math.max(0,p.textProgress*(letters.length+3)-i)/3)}},letter)))
          }else content=React.createElement(Text,{style:textStyle},p.text)
          break
        }
        case "shape":
          if(native)content=React.createElement(View,{style:{width:"100%",height:"100%",backgroundColor:p.fill,borderColor:p.stroke,borderWidth:p.strokeWidth,borderRadius:p.cornerRadius}})
          else {style.backgroundColor=p.fill;style.borderColor=p.stroke;style.borderWidth=p.strokeWidth;style.borderStyle="solid"}
          break
        case "image": content=p.image?React.createElement(Image,native?{source:{uri:p.image},style:{width:"100%",height:"100%"},resizeMode:"contain"}:{src:p.image,style:{width:"100%",height:"100%",objectFit:"contain"}}):null;break
        case "path": {
          if(native) {
            content=React.createElement(Shape,{commands:pathCommands(p.path),motionFill:p.fill,motionStroke:p.stroke,motionStrokeWidth:p.strokeWidth,motionProgress:p.pathProgress,style:{width:"100%",height:"100%"}})
          }else content=React.createElement("svg",{width:"100%",height:"100%",viewBox:`0 0 ${p.width} ${p.height}`},React.createElement("path",{d:p.path,fill:p.fill,stroke:p.stroke,strokeWidth:p.strokeWidth,pathLength:1,strokeDasharray:1,strokeDashoffset:1-p.pathProgress}))
          break
        }
        default: content=(children.get(node.id)??[]).map(renderNode)
      }
      const config={fps:document.fps,width:p.width,height:p.height,durationInFrames:node.durationFrames}
      const body=React.createElement(ConfigContext.Provider,{value:config},React.createElement(TimelineContext.Provider,{value:{frame:state.localFrame}},content))
      if(native)return React.createElement(View,{key:node.id,style,collapsable:false},React.createElement(Mask,{pointerEvents:"none",style:{position:"absolute",left:0,top:0,width:0,height:0},motionMask:p.mask,motionReveal:p.reveal,motionBlur:p.blur}),body)
      return React.createElement(View,{key:node.id,style,"data-motion-node":node.id},body)
    }
    const m=evaluated.camera
    const cameraStyle={position:"absolute",left:0,top:0,width:document.width,height:document.height,
      transform:native?[{matrix:[m[0],m[1],0,0,m[2],m[3],0,0,0,0,1,0,m[4],m[5],0,1]}]:`matrix(${m.join(",")})`,transformOrigin:native?[0,0,0]:"0 0"}
    return React.createElement(View,{style:{position:"relative",width:document.width,height:document.height,backgroundColor:document.background,overflow:"hidden"}},
      !native?document.components.filter(c=>c.stylesheet).map(c=>React.createElement("style",{key:c.id},c.stylesheet)):null,
      React.createElement(View,{style:cameraStyle},(children.get(null)??[]).map(renderNode)))
  }
  return {SceneDocument,MotionSlot,FrameEpochProvider:FrameEpochContext.Provider}
}
