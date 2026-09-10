import React from "react"
import {Image as NativeImage, View, requireNativeComponent} from "react-native"
import {embeddedImageSource} from "./image-source"

const pending = new Set()
const listeners = new Set()
let generation = 0
let failure = null
const emit = () => { generation++; for (const listener of listeners) listener() }
const subscribe = listener => { listeners.add(listener); return () => listeners.delete(listener) }
const snapshot = () => generation
export function resetAssetErrors() { failure = null }

export const Image = React.forwardRef(function MotionImage({source,onLoad,onError,...props},ref) {
  const resolved = React.useMemo(() => embeddedImageSource(source), [source])
  const key = Array.isArray(resolved) ? resolved.map(item => item.uri).join("\0") : resolved?.uri
  const identity = React.useMemo(() => ({}), [key])
  const currentIdentity = React.useRef(identity)
  const active = React.useRef(false)
  currentIdentity.current = identity
  const loaded = React.useRef(null)
  React.useLayoutEffect(() => {
    active.current = true
    if (resolved && loaded.current !== identity) { pending.add(identity); emit() }
    return () => { active.current = false; if (pending.delete(identity)) emit() }
  }, [identity])
  const finish = error => {
    if (!active.current || currentIdentity.current !== identity) return
    loaded.current = identity
    if (error) failure = String(error.nativeEvent?.error ?? "Image could not be decoded")
    pending.delete(identity)
    emit()
  }
  if (!resolved) return <View {...props} ref={ref} />
  return <NativeImage {...props} source={resolved} ref={ref}
    onLoad={event => { finish(); onLoad?.(event) }}
    onError={event => { finish(event); onError?.(event) }} />
})

export const ImageBackground = React.forwardRef(function MotionImageBackground({children,style,imageStyle,...props},ref) {
  return <View style={style}><Image {...props} ref={ref} style={[{position:"absolute",left:0,top:0,width:"100%",height:"100%"},imageStyle]} />{children}</View>
})

const NativeMarker = requireNativeComponent("PalmierFrameMarker")
export function FrameMarker({requestID,error}) {
  const version = React.useSyncExternalStore(subscribe,snapshot)
  const [ready,setReady] = React.useState(null)
  React.useLayoutEffect(() => {
    setReady(pending.size === 0 || error ? {requestID,error:error ?? failure,version} : null)
  }, [requestID,error,version])
  if (!ready || ready.requestID !== requestID || ready.version !== version) return null
  return <NativeMarker collapsable={false} payload={JSON.stringify(ready)}
    style={{position:"absolute",left:0,top:0,width:1,height:1,opacity:0}} />
}
