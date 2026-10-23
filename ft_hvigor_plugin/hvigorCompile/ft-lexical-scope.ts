/** Value bindings visible at a call site, including declarations later in the same scope. */
interface Scope {
  parent?: Scope;
  functionScope: boolean;
  bindings: Map<string, any>;
}

export function createLexicalResolver(ts: any, source: any): (location: any, name: string) => any | undefined {
  const scopes = new WeakMap<object, Scope>();
  const root: Scope = { functionScope: true, bindings: new Map() };
  const bind = (scope: Scope, name: any, declaration: any): void => {
    if (!name) return;
    if (ts.isIdentifier(name)) scope.bindings.set(name.text, declaration);
    else if (name.elements) name.elements.forEach((element: any) => {
      if (ts.isBindingElement(element)) bind(scope, element.name, declaration);
    });
  };
  const walk = (node: any, outer: Scope): void => {
    if ((ts.isFunctionDeclaration(node) || ts.isClassDeclaration(node) || ts.isEnumDeclaration(node)) && node.name) {
      bind(outer, node.name, node);
    }
    let scope = outer;
    const functionLike = ts.isFunctionLike(node);
    if (functionLike || ts.isBlock(node) || ts.isCaseBlock(node) || ts.isCatchClause(node) ||
      ts.isForStatement(node) || ts.isForInStatement(node) || ts.isForOfStatement(node) ||
      ts.isClassDeclaration(node) || ts.isClassExpression(node)) {
      scope = { parent: outer, functionScope: functionLike, bindings: new Map() };
    }
    scopes.set(node, scope);
    if (functionLike) {
      if (ts.isFunctionExpression(node) && node.name) bind(scope, node.name, node);
      node.parameters.forEach((parameter: any) => bind(scope, parameter.name, parameter));
    }
    if ((ts.isClassDeclaration(node) || ts.isClassExpression(node)) && node.name) bind(scope, node.name, node);
    if (ts.isVariableDeclaration(node)) {
      const list = node.parent;
      let target = scope;
      if (ts.isVariableDeclarationList(list) && !(list.flags & ts.NodeFlags.BlockScoped)) {
        while (!target.functionScope && target.parent) target = target.parent;
      }
      bind(target, node.name, node);
    }
    if (ts.isImportDeclaration(node) && node.importClause && !node.importClause.isTypeOnly) {
      const clause = node.importClause;
      if (clause.name) bind(scope, clause.name, clause);
      const bindings = clause.namedBindings;
      if (bindings && ts.isNamespaceImport(bindings)) bind(scope, bindings.name, bindings);
      else if (bindings) bindings.elements.forEach((element: any) => {
        if (!element.isTypeOnly) bind(scope, element.name, element);
      });
    }
    if (ts.isImportEqualsDeclaration(node) && !node.isTypeOnly) bind(scope, node.name, node);
    ts.forEachChild(node, (child: any) => walk(child, scope));
  };
  walk(source, root);
  return (location: any, name: string): any | undefined => {
    for (let scope = scopes.get(location); scope; scope = scope.parent) {
      if (scope.bindings.has(name)) return scope.bindings.get(name);
    }
    return undefined;
  };
}
