/** Reserve generated identifiers across all scopes and every nested rewrite. */
export function allocateName(identifiers: Set<string>, base: string): string {
  let candidate = base;
  let suffix = 1;
  while (identifiers.has(candidate)) candidate = `${base}${suffix++}`;
  identifiers.add(candidate);
  return candidate;
}

export function collectIdentifierNames(ts: any, source: any): Set<string> {
  const identifiers = new Set<string>();
  const visit = (node: any): void => {
    if (ts.isIdentifier(node)) identifiers.add(node.text);
    if (node.name && ts.isStringLiteral(node.name)) identifiers.add(node.name.text);
    ts.forEachChild(node, visit);
  };
  visit(source);
  return identifiers;
}
