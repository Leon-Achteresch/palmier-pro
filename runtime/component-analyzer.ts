import ts from "typescript"

type Value = string | number | boolean | null | Value[] | {[key:string]:Value}
function literal(node: ts.Expression | undefined): Value | undefined {
  if (!node) return undefined
  if (ts.isAsExpression(node) || ts.isSatisfiesExpression(node) || ts.isParenthesizedExpression(node)) return literal(node.expression)
  if (ts.isStringLiteralLike(node)) return node.text
  if (ts.isNumericLiteral(node)) return Number(node.text)
  if (node.kind === ts.SyntaxKind.TrueKeyword) return true
  if (node.kind === ts.SyntaxKind.FalseKeyword) return false
  if (node.kind === ts.SyntaxKind.NullKeyword) return null
  if (ts.isPrefixUnaryExpression(node) && node.operator === ts.SyntaxKind.MinusToken) {
    const value=literal(node.operand);return typeof value === "number" ? -value : undefined
  }
  if (ts.isArrayLiteralExpression(node)) {
    const values=node.elements.map(x=>literal(x as ts.Expression))
    return values.every(x=>x!==undefined)?values as Value[]:undefined
  }
  if (ts.isObjectLiteralExpression(node)) {
    const result: {[key:string]:Value}={}
    for (const prop of node.properties) {
      if (!ts.isPropertyAssignment(prop)) continue
      const value=literal(prop.initializer),name=prop.name.getText().replace(/^["']|["']$/g,"")
      if (value!==undefined && !["__proto__","constructor","prototype"].includes(name)) result[name]=value
    }
    return result
  }
  return undefined
}
function unwrap(node:ts.Expression|undefined): ts.Expression|undefined {
  while(node&&(ts.isAsExpression(node)||ts.isSatisfiesExpression(node)||ts.isParenthesizedExpression(node)))node=node.expression
  return node
}
function field(node:ts.Expression|undefined,name:string): ts.Expression|undefined {
  node=unwrap(node)
  if(!node||!ts.isObjectLiteralExpression(node))return
  const prop=node.properties.find(p=>p.name?.getText().replace(/^["']|["']$/g,"")===name)
  return prop&&ts.isPropertyAssignment(prop)?prop.initializer:prop&&ts.isShorthandPropertyAssignment(prop)?prop.name:undefined
}
function analyze(source:string,filename:string,selected="default") {
  const file=ts.createSourceFile(filename,source,ts.ScriptTarget.Latest,true,filename.endsWith("x")?ts.ScriptKind.TSX:ts.ScriptKind.TS)
  const declarations=new Map<string,ts.Node>(),types=new Map<string,ts.TypeNode|ts.InterfaceDeclaration>()
  const exports=new Map<string,ts.Node>(),imports: {module:string;names:string[]}[]=[]
  let meta:ts.Expression|undefined
  const exported=(node:ts.Node)=>ts.canHaveModifiers(node)&&ts.getModifiers(node)?.some(m=>m.kind===ts.SyntaxKind.ExportKeyword)
  const isDefault=(node:ts.Node)=>ts.canHaveModifiers(node)&&ts.getModifiers(node)?.some(m=>m.kind===ts.SyntaxKind.DefaultKeyword)
  for(const statement of file.statements) {
    if(ts.isInterfaceDeclaration(statement))types.set(statement.name.text,statement)
    if(ts.isTypeAliasDeclaration(statement))types.set(statement.name.text,statement.type)
    if(ts.isImportDeclaration(statement)&&ts.isStringLiteral(statement.moduleSpecifier)) {
      const bindings=statement.importClause?.namedBindings
      imports.push({module:statement.moduleSpecifier.text,names:[...(statement.importClause?.name?[statement.importClause.name.text]:[]),...(bindings&&ts.isNamedImports(bindings)?bindings.elements.map(e=>e.name.text):[])]})
    }
    if(ts.isFunctionDeclaration(statement)) {
      if(statement.name)declarations.set(statement.name.text,statement)
      if(exported(statement))exports.set(isDefault(statement)?"default":statement.name?.text??"default",statement)
    }
    if(ts.isVariableStatement(statement))for(const declaration of statement.declarationList.declarations) {
      if(!ts.isIdentifier(declaration.name))continue
      declarations.set(declaration.name.text,declaration)
      if(exported(statement))exports.set(declaration.name.text,declaration)
    }
    if(ts.isExportAssignment(statement)) {meta=statement.expression;exports.set("default",statement.expression)}
  }
  for(const statement of file.statements)if(ts.isExportDeclaration(statement)&&statement.exportClause&&ts.isNamedExports(statement.exportClause)) {
    for(const specifier of statement.exportClause.elements) {
      const node=declarations.get((specifier.propertyName??specifier.name).text)
      if(node)exports.set(specifier.name.text,node)
    }
  }
  function resolveExpression(node:ts.Expression|undefined):ts.Expression|undefined {
    if(node&&ts.isIdentifier(node)) {
      const declaration=declarations.get(node.text)
      if(declaration&&ts.isVariableDeclaration(declaration))return unwrap(declaration.initializer)
    }
    return unwrap(node)
  }
  meta=resolveExpression(meta)
  const isStory=/\.stories\.[jt]sx?$/.test(filename)
  const target=exports.get(selected)
  const initializer=target&&ts.isVariableDeclaration(target)?unwrap(target.initializer):target
  const func=initializer&&(ts.isFunctionDeclaration(initializer)||ts.isArrowFunction(initializer)||ts.isFunctionExpression(initializer))?initializer:undefined
  const defaults:Record<string,Value>={}
  if(func?.parameters[0]&&ts.isObjectBindingPattern(func.parameters[0].name))for(const element of func.parameters[0].name.elements) {
    const value=literal(element.initializer)
    if(value!==undefined)defaults[(element.propertyName??element.name).getText()]=value
  }
  let propType=func?.parameters[0]?.type
  if(!propType&&target&&ts.isVariableDeclaration(target)&&target.type&&ts.isTypeReferenceNode(target.type))propType=target.type.typeArguments?.[0]
  if(!propType&&initializer&&ts.isCallExpression(initializer)) {
    propType=initializer.typeArguments?.[initializer.expression.getText().includes("forwardRef")?1:0]
    const callback=initializer.arguments[0]
    if(!propType&&callback&&(ts.isArrowFunction(callback)||ts.isFunctionExpression(callback)))propType=callback.parameters[0]?.type
  }
  function members(type:ts.TypeNode|ts.InterfaceDeclaration|undefined,seen=new Set<string>()):ts.TypeElement[] {
    if(!type)return[]
    if(ts.isTypeReferenceNode(type)) {
      const name=type.typeName.getText()
      if(seen.has(name))return[]
      seen.add(name);return members(types.get(name),seen)
    }
    if(ts.isInterfaceDeclaration(type)||ts.isTypeLiteralNode(type))return [...type.members]
    if(ts.isIntersectionTypeNode(type))return type.types.flatMap(t=>members(t,seen))
    return[]
  }
  const propMap=new Map<string,any>()
  function add(id:string,value:Value|undefined,type?:ts.TypeNode) {
    let kind:string|undefined,choices:string[]=[]
    if(type?.kind===ts.SyntaxKind.NumberKeyword)kind="number"
    if(type?.kind===ts.SyntaxKind.StringKeyword)kind="string"
    if(type?.kind===ts.SyntaxKind.BooleanKeyword)kind="boolean"
    if(type&&ts.isUnionTypeNode(type)) {
      const literals=type.types.filter(t=>t.kind!==ts.SyntaxKind.UndefinedKeyword&&t.kind!==ts.SyntaxKind.NullKeyword)
      if(literals.every(t=>ts.isLiteralTypeNode(t)&&ts.isStringLiteral(t.literal))) {
        choices=literals.map(t=>(t as ts.LiteralTypeNode).literal).map(t=>(t as ts.StringLiteral).text);kind="choice"
      }
    }
    if(!kind&&value!==null&&["number","string","boolean"].includes(typeof value))kind=typeof value
    if(!kind||!["number","string","boolean","choice"].includes(kind))return
    if(kind==="string"&&typeof value==="string"&&/^#[0-9a-fA-F]{3,8}$/.test(value))kind="color"
    propMap.set(id,{id,label:id,kind,defaultValue:value??(kind==="number"?0:kind==="boolean"?false:choices[0]??""),choices,animatable:true})
  }
  for(const member of members(propType))if(ts.isPropertySignature(member)&&member.name)add(member.name.getText().replace(/^["']|["']$/g,""),defaults[member.name.getText()],member.type)
  for(const [name,value]of Object.entries(defaults))if(!propMap.has(name))add(name,value)
  const fixtures:Record<string,Record<string,Value>>={}
  if(isStory) {
    const base=literal(field(meta,"args")) as Record<string,Value>|undefined
    for(const [name,node]of exports) {
      if(name==="default"||!ts.isVariableDeclaration(node))continue
      const args=literal(field(node.initializer,"args")) as Record<string,Value>|undefined
      if(base||args)fixtures[name]={...base,...args}
    }
    for(const [name,value]of Object.entries(fixtures[selected]??base??{}))add(name,value)
    const argTypes=resolveExpression(field(meta,"argTypes"))
    if(argTypes&&ts.isObjectLiteralExpression(argTypes))for(const prop of argTypes.properties)if(ts.isPropertyAssignment(prop)) {
      const name=prop.name.getText().replace(/^["']|["']$/g,""),options=literal(field(prop.initializer,"options"))
      if(Array.isArray(options)&&options.every(x=>typeof x==="string")&&propMap.has(name))Object.assign(propMap.get(name),{kind:"choice",choices:options})
    }
    for(const fixture of Object.values(fixtures))for(const key of Object.keys(fixture))if(!propMap.has(key))delete fixture[key]
  }
  const diagnostics:string[]=[]
  function visit(node:ts.Node) {
    if(ts.isCallExpression(node)) {
      const name=node.expression.getText()
      if(/^(?:globalThis\.|window\.|global\.)?(setTimeout|setInterval|requestAnimationFrame|fetch)$/.test(name)||/^(Animated|LayoutAnimation)\./.test(name))diagnostics.push(`${name} requires a frame-driven adapter`)
    }
    ts.forEachChild(node,visit)
  }
  visit(file)
  return {exports:[...exports.keys()].filter(x=>x==="default"||/^[A-Z]/.test(x)),props:[...propMap.values()],fixtures,imports,isStory,diagnostics:[...new Set(diagnostics)]}
}
;(globalThis as any).PalmierComponentAnalysis={analyze:(source:string,filename:string,selected:string)=>JSON.stringify(analyze(source,filename,selected))}
