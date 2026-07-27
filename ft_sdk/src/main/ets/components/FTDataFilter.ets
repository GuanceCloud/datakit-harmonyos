import { DataType } from './enum/Enums';

/** Values that can be compared by a local data-filter rule. */
export type FTDataFilterValue = string | number | boolean;

type FilterCategory = 'logging' | 'rum';

interface FilterValues {
  get(key: string): FTDataFilterValue | null;
}

interface FilterExpression {
  evaluate(values: FilterValues): boolean;
}

interface FilterValueExpression extends FilterExpression {
  resolve(values: FilterValues): FTDataFilterValue | null;
}

enum FilterTokenType {
  EOF,
  LEFT_BRACE,
  RIGHT_BRACE,
  LEFT_PAREN,
  RIGHT_PAREN,
  LEFT_BRACKET,
  RIGHT_BRACKET,
  COMMA,
  SEMICOLON,
  IDENTIFIER,
  STRING,
  NUMBER,
  BOOLEAN,
  AND,
  OR,
  EQ,
  NEQ,
  GT,
  GTE,
  LT,
  LTE,
  IN,
  NOT_IN,
  MATCH,
  NOT_MATCH
}

class FilterToken {
  public type: FilterTokenType;
  public text: string;
  public value: FTDataFilterValue | null;

  constructor(type: FilterTokenType, text: string, value: FTDataFilterValue | null = null) {
    this.type = type;
    this.text = text;
    this.value = value;
  }
}

class IdentifierExpression implements FilterValueExpression {
  private key: string;

  constructor(key: string) {
    this.key = key;
  }

  resolve(values: FilterValues): FTDataFilterValue | null {
    return values.get(this.key);
  }

  evaluate(values: FilterValues): boolean {
    return this.resolve(values) === true;
  }
}

class LiteralExpression implements FilterValueExpression {
  private literal: FTDataFilterValue;

  constructor(literal: FTDataFilterValue) {
    this.literal = literal;
  }

  resolve(_values: FilterValues): FTDataFilterValue | null {
    return this.literal;
  }

  rawValue(): FTDataFilterValue {
    return this.literal;
  }

  evaluate(_values: FilterValues): boolean {
    return this.literal === true;
  }
}

class RegexExpression implements FilterValueExpression {
  private pattern: RegExp;

  constructor(pattern: RegExp) {
    this.pattern = pattern;
  }

  resolve(_values: FilterValues): FTDataFilterValue | null {
    return null;
  }

  matches(value: string): boolean {
    return this.pattern.test(value);
  }

  evaluate(_values: FilterValues): boolean {
    return false;
  }
}

class BinaryExpression implements FilterExpression {
  private operator: FilterTokenType;
  private left: FilterExpression;
  private right: FilterExpression;

  constructor(operator: FilterTokenType, left: FilterExpression, right: FilterExpression) {
    this.operator = operator;
    this.left = left;
    this.right = right;
  }

  evaluate(values: FilterValues): boolean {
    if (this.operator === FilterTokenType.AND) {
      return this.left.evaluate(values) && this.right.evaluate(values);
    }
    return this.left.evaluate(values) || this.right.evaluate(values);
  }
}

class ListExpression implements FilterExpression {
  private operator: FilterTokenType;
  private left: FilterValueExpression;
  private items: Array<FilterValueExpression>;

  constructor(operator: FilterTokenType, left: FilterValueExpression, items: Array<FilterValueExpression>) {
    this.operator = operator;
    this.left = left;
    this.items = items;
  }

  evaluate(values: FilterValues): boolean {
    if (this.items.length === 0) {
      return false;
    }

    const leftValue = this.left.resolve(values);
    if (leftValue === null) {
      return false;
    }

    let matched = false;
    for (let i = 0; i < this.items.length; i++) {
      const item = this.items[i];
      if (this.operator === FilterTokenType.MATCH || this.operator === FilterTokenType.NOT_MATCH) {
        if (this.matches(leftValue, item)) {
          matched = true;
          break;
        }
      } else {
        const itemValue = item.resolve(values);
        if (itemValue !== null && this.isEqual(leftValue, itemValue)) {
          matched = true;
          break;
        }
      }
    }

    return this.operator === FilterTokenType.NOT_IN || this.operator === FilterTokenType.NOT_MATCH
      ? !matched
      : matched;
  }

  private matches(value: FTDataFilterValue, item: FilterValueExpression): boolean {
    if (typeof value !== 'string') {
      return false;
    }
    if (item instanceof RegexExpression) {
      return item.matches(value);
    }
    const pattern = item.resolve(new EmptyFilterValues());
    if (typeof pattern !== 'string') {
      return false;
    }
    try {
      return new RegExp(pattern).test(value);
    } catch (_error) {
      return false;
    }
  }

  private isEqual(left: FTDataFilterValue, right: FTDataFilterValue): boolean {
    if (typeof left === 'number' && typeof right === 'number') {
      return left === right;
    }
    return left === right;
  }
}

class EmptyFilterValues implements FilterValues {
  get(_key: string): FTDataFilterValue | null {
    return null;
  }
}

class FilterParser {
  private lexer: FilterLexer;
  private current: FilterToken;

  constructor(input: string) {
    this.lexer = new FilterLexer(input);
    this.current = this.lexer.next();
  }

  parseConditions(): Array<FilterExpression> {
    const conditions: Array<FilterExpression> = [];
    while (this.current.type !== FilterTokenType.EOF) {
      if (this.match(FilterTokenType.SEMICOLON) || this.match(FilterTokenType.COMMA)) {
        continue;
      }
      if (!this.match(FilterTokenType.LEFT_BRACE)) {
        this.advance();
        continue;
      }
      if (this.match(FilterTokenType.RIGHT_BRACE)) {
        continue;
      }
      const expression = this.parseOr();
      this.expect(FilterTokenType.RIGHT_BRACE);
      conditions.push(expression);
    }
    return conditions;
  }

  private parseOr(): FilterExpression {
    let expression = this.parseAnd();
    while (this.match(FilterTokenType.OR)) {
      expression = new BinaryExpression(FilterTokenType.OR, expression, this.parseAnd());
    }
    return expression;
  }

  private parseAnd(): FilterExpression {
    let expression = this.parseCompare();
    while (this.match(FilterTokenType.AND)) {
      expression = new BinaryExpression(FilterTokenType.AND, expression, this.parseCompare());
    }
    return expression;
  }

  private parseCompare(): FilterExpression {
    if (this.match(FilterTokenType.LEFT_PAREN)) {
      const expression = this.parseOr();
      this.expect(FilterTokenType.RIGHT_PAREN);
      return expression;
    }

    const left = new IdentifierExpression(this.parseFieldName());
    const operator = this.current.type;
    if (operator !== FilterTokenType.IN && operator !== FilterTokenType.NOT_IN &&
      operator !== FilterTokenType.MATCH && operator !== FilterTokenType.NOT_MATCH) {
      throw new Error('Unsupported filter operator');
    }
    this.advance();
    let values = this.parseRuleValues();
    if (operator === FilterTokenType.MATCH || operator === FilterTokenType.NOT_MATCH) {
      values = this.compileRegexValues(values);
    }
    return new ListExpression(operator, left, values);
  }

  private parseFieldName(): string {
    const token = this.current;
    if (token.type !== FilterTokenType.IDENTIFIER && token.type !== FilterTokenType.STRING) {
      throw new Error('Expected a filter field name');
    }
    this.advance();
    return token.type === FilterTokenType.STRING ? String(token.value) : token.text;
  }

  private compileRegexValues(values: Array<FilterValueExpression>): Array<FilterValueExpression> {
    const regexValues: Array<FilterValueExpression> = [];
    for (let i = 0; i < values.length; i++) {
      const value = values[i];
      if (!(value instanceof LiteralExpression) || typeof value.rawValue() !== 'string') {
        continue;
      }
      try {
        regexValues.push(new RegexExpression(new RegExp(value.rawValue() as string)));
      } catch (_error) {
        // Keep Android parity: an invalid regular expression is ignored.
      }
    }
    return regexValues;
  }

  private parseRuleValues(): Array<FilterValueExpression> {
    if (!this.match(FilterTokenType.LEFT_BRACKET)) {
      return this.parseBareRuleValues();
    }

    const values: Array<FilterValueExpression> = [];
    while (this.current.type !== FilterTokenType.RIGHT_BRACKET && this.current.type !== FilterTokenType.EOF) {
      if (this.match(FilterTokenType.COMMA)) {
        continue;
      }
      values.push(this.parseRuleValue());
      this.match(FilterTokenType.COMMA);
    }
    this.expect(FilterTokenType.RIGHT_BRACKET);
    return values;
  }

  private parseBareRuleValues(): Array<FilterValueExpression> {
    const values: Array<FilterValueExpression> = [];
    while (!this.isRuleValueTerminator(this.current.type)) {
      values.push(this.parseRuleValue());
      if (!this.match(FilterTokenType.COMMA)) {
        break;
      }
    }
    return values;
  }

  private isRuleValueTerminator(type: FilterTokenType): boolean {
    return type === FilterTokenType.RIGHT_BRACE || type === FilterTokenType.RIGHT_PAREN ||
      type === FilterTokenType.AND || type === FilterTokenType.OR || type === FilterTokenType.EOF;
  }

  private parseRuleValue(): FilterValueExpression {
    const token = this.current;
    if (token.type !== FilterTokenType.IDENTIFIER && token.type !== FilterTokenType.STRING &&
      token.type !== FilterTokenType.NUMBER && token.type !== FilterTokenType.BOOLEAN) {
      throw new Error('Expected a filter value');
    }
    this.advance();
    return new LiteralExpression(token.type === FilterTokenType.IDENTIFIER ? token.text : token.value as FTDataFilterValue);
  }

  private match(type: FilterTokenType): boolean {
    if (this.current.type !== type) {
      return false;
    }
    this.advance();
    return true;
  }

  private expect(type: FilterTokenType): void {
    if (!this.match(type)) {
      throw new Error('Invalid local data-filter rule');
    }
  }

  private advance(): void {
    this.current = this.lexer.next();
  }
}

class FilterLexer {
  private position: number = 0;
  private input: string;

  constructor(input: string) {
    this.input = input;
  }

  next(): FilterToken {
    this.skipWhitespaceAndComments();
    if (this.position >= this.input.length) {
      return new FilterToken(FilterTokenType.EOF, '');
    }

    const character = this.input.charAt(this.position);
    switch (character) {
      case '{': return this.singleCharacterToken(FilterTokenType.LEFT_BRACE, character);
      case '}': return this.singleCharacterToken(FilterTokenType.RIGHT_BRACE, character);
      case '(': return this.singleCharacterToken(FilterTokenType.LEFT_PAREN, character);
      case ')': return this.singleCharacterToken(FilterTokenType.RIGHT_PAREN, character);
      case '[': return this.singleCharacterToken(FilterTokenType.LEFT_BRACKET, character);
      case ']': return this.singleCharacterToken(FilterTokenType.RIGHT_BRACKET, character);
      case ',': return this.singleCharacterToken(FilterTokenType.COMMA, character);
      case ';': return this.singleCharacterToken(FilterTokenType.SEMICOLON, character);
      case '\'':
      case '"':
      case '`':
        return this.readString(character);
      case '=':
        this.position++;
        if (this.peek('=')) {
          this.position++;
        }
        return new FilterToken(FilterTokenType.EQ, '=');
      case '!':
        this.position++;
        if (this.peek('=')) {
          this.position++;
          return new FilterToken(FilterTokenType.NEQ, '!=');
        }
        throw new Error('Unexpected filter character');
      case '>':
        this.position++;
        if (this.peek('=')) {
          this.position++;
          return new FilterToken(FilterTokenType.GTE, '>=');
        }
        return new FilterToken(FilterTokenType.GT, '>');
      case '<':
        this.position++;
        if (this.peek('=')) {
          this.position++;
          return new FilterToken(FilterTokenType.LTE, '<=');
        }
        return new FilterToken(FilterTokenType.LT, '<');
      case '&':
        if (this.peekNext('&')) {
          this.position += 2;
          return new FilterToken(FilterTokenType.AND, '&&');
        }
        break;
      case '|':
        if (this.peekNext('|')) {
          this.position += 2;
          return new FilterToken(FilterTokenType.OR, '||');
        }
        break;
      default:
        break;
    }

    if (this.isNumberStart(character)) {
      return this.readNumber();
    }
    if (this.isIdentifierStart(character)) {
      return this.readIdentifier();
    }
    throw new Error('Unexpected filter character');
  }

  private singleCharacterToken(type: FilterTokenType, text: string): FilterToken {
    this.position++;
    return new FilterToken(type, text);
  }

  private skipWhitespaceAndComments(): void {
    while (this.position < this.input.length) {
      const character = this.input.charAt(this.position);
      if (character === ' ' || character === '\t' || character === '\r' || character === '\n') {
        this.position++;
      } else if (character === '#') {
        while (this.position < this.input.length && this.input.charAt(this.position) !== '\n') {
          this.position++;
        }
      } else {
        return;
      }
    }
  }

  private readIdentifier(): FilterToken {
    const start = this.position;
    this.position++;
    while (this.position < this.input.length && this.isIdentifierPart(this.input.charAt(this.position))) {
      this.position++;
    }
    const text = this.input.substring(start, this.position);
    const keyword = text.toLowerCase();
    if (keyword === 'and') return new FilterToken(FilterTokenType.AND, text);
    if (keyword === 'or') return new FilterToken(FilterTokenType.OR, text);
    if (keyword === 'in') return new FilterToken(FilterTokenType.IN, text);
    if (keyword === 'not') {
      const saved = this.position;
      this.skipWhitespaceAndComments();
      if (this.readKeyword('in')) return new FilterToken(FilterTokenType.NOT_IN, 'not in');
      if (this.readKeyword('match')) return new FilterToken(FilterTokenType.NOT_MATCH, 'not match');
      this.position = saved;
    }
    if (keyword === 'notin' || keyword === 'not_in') return new FilterToken(FilterTokenType.NOT_IN, text);
    if (keyword === 'match') return new FilterToken(FilterTokenType.MATCH, text);
    if (keyword === 'notmatch' || keyword === 'not_match') return new FilterToken(FilterTokenType.NOT_MATCH, text);
    if (keyword === 'true' || keyword === 'false') return new FilterToken(FilterTokenType.BOOLEAN, text, keyword === 'true');
    return new FilterToken(FilterTokenType.IDENTIFIER, text, text);
  }

  private readString(quote: string): FilterToken {
    let value = '';
    this.position++;
    while (this.position < this.input.length) {
      const character = this.input.charAt(this.position++);
      if (character === quote) {
        return new FilterToken(FilterTokenType.STRING, value, value);
      }
      if (character === '\\' && this.position < this.input.length) {
        const escaped = this.input.charAt(this.position++);
        if (escaped === 'n') value += '\n';
        else if (escaped === 't') value += '\t';
        else if (escaped === 'r') value += '\r';
        else value += escaped;
      } else {
        value += character;
      }
    }
    throw new Error('Unterminated filter string');
  }

  private readNumber(): FilterToken {
    const start = this.position;
    if (this.input.charAt(this.position) === '-') {
      this.position++;
    }
    const digitsStart = this.position;
    while (this.position < this.input.length && this.isDigit(this.input.charAt(this.position))) {
      this.position++;
    }
    if (digitsStart === this.position) {
      throw new Error('Invalid filter number');
    }
    if (this.position < this.input.length && this.input.charAt(this.position) === '.') {
      this.position++;
      while (this.position < this.input.length && this.isDigit(this.input.charAt(this.position))) {
        this.position++;
      }
    }
    const text = this.input.substring(start, this.position);
    const value = Number(text);
    if (Number.isNaN(value)) {
      throw new Error('Invalid filter number');
    }
    return new FilterToken(FilterTokenType.NUMBER, text, value);
  }

  private isIdentifierStart(character: string): boolean {
    return this.isLetter(character) || character === '_' || character === '.' || character === '*' ||
      character === '^' || character === '$' || character === '/' || character === '|';
  }

  private isIdentifierPart(character: string): boolean {
    return this.isLetter(character) || this.isDigit(character) || character === '_' || character === '.' ||
      character === '-' || character === '*' || character === '+' || character === '?' || character === '/' ||
      character === ':' || character === '%' || character === '^' || character === '$' || character === '|';
  }

  private isLetter(character: string): boolean {
    return (character >= 'A' && character <= 'Z') || (character >= 'a' && character <= 'z');
  }

  private isDigit(character: string): boolean {
    return character >= '0' && character <= '9';
  }

  private isNumberStart(character: string): boolean {
    return this.isDigit(character) || character === '-';
  }

  private readKeyword(keyword: string): boolean {
    const end = this.position + keyword.length;
    if (end > this.input.length || this.input.substring(this.position, end).toLowerCase() !== keyword) {
      return false;
    }
    if (end < this.input.length && this.isIdentifierPart(this.input.charAt(end))) {
      return false;
    }
    this.position = end;
    return true;
  }

  private peek(character: string): boolean {
    return this.position < this.input.length && this.input.charAt(this.position) === character;
  }

  private peekNext(character: string): boolean {
    return this.position + 1 < this.input.length && this.input.charAt(this.position) === character &&
      this.input.charAt(this.position + 1) === character;
  }
}

class PointFilterValues implements FilterValues {
  private category: FilterCategory;
  private measurement: string;
  private tags: Map<string, FTDataFilterValue>;
  private fields: Map<string, FTDataFilterValue>;

  constructor(category: FilterCategory, measurement: string, tags: Map<string, FTDataFilterValue>, fields: Map<string, FTDataFilterValue>) {
    this.category = category;
    this.measurement = measurement;
    this.tags = tags;
    this.fields = fields;
  }

  get(key: string): FTDataFilterValue | null {
    if (this.tags.has(key)) {
      return this.tags.get(key) as FTDataFilterValue;
    }
    if (this.fields.has(key)) {
      return this.fields.get(key) as FTDataFilterValue;
    }
    if (key === 'category') {
      return this.category;
    }
    if (key === 'source' || key === 'measurement' || key === 'class') {
      return this.measurement;
    }
    return null;
  }
}

/**
 * DataKit-compatible local filter evaluator. A matching rule means the data point must be dropped.
 * This class is internal; SDK consumers configure it through FTSDKConfig.
 */
export class FTDataFilter {
  static readonly CATEGORY_LOGGING: FilterCategory = 'logging';
  static readonly CATEGORY_RUM: FilterCategory = 'rum';

  private conditions: Map<FilterCategory, Array<FilterExpression>>;

  private constructor(conditions: Map<FilterCategory, Array<FilterExpression>>) {
    this.conditions = conditions;
  }

  static empty(): FTDataFilter {
    return new FTDataFilter(new Map<FilterCategory, Array<FilterExpression>>());
  }

  static compile(filters: Map<string, Array<string>> | null): FTDataFilter {
    const conditions = new Map<FilterCategory, Array<FilterExpression>>();
    if (filters === null || filters.size === 0) {
      return new FTDataFilter(conditions);
    }

    filters.forEach((rules: Array<string>, rawCategory: string) => {
      const category = FTDataFilter.normalizeCategory(rawCategory);
      if (category === null || !rules) {
        return;
      }
      const categoryConditions: Array<FilterExpression> = [];
      for (let i = 0; i < rules.length; i++) {
        const rule = rules[i];
        if (!rule || rule.trim().length === 0) {
          continue;
        }
        const expressions = FTDataFilter.parseConditions(rule);
        for (let j = 0; j < expressions.length; j++) {
          categoryConditions.push(expressions[j]);
        }
      }
      if (categoryConditions.length > 0) {
        conditions.set(category, categoryConditions);
      }
    });
    return new FTDataFilter(conditions);
  }

  isEmpty(): boolean {
    return this.conditions.size === 0;
  }

  isFiltered(
    dataType: DataType,
    measurement: string,
    tags: Map<string, FTDataFilterValue>,
    fields: Map<string, FTDataFilterValue>
  ): boolean {
    const category = FTDataFilter.categoryOf(dataType);
    if (category === null) {
      return false;
    }
    const expressions = this.conditions.get(category);
    if (expressions === undefined || expressions.length === 0) {
      return false;
    }
    const values = new PointFilterValues(category, measurement, tags, fields);
    for (let i = 0; i < expressions.length; i++) {
      if (expressions[i].evaluate(values)) {
        return true;
      }
    }
    return false;
  }

  isFilteredLine(dataType: DataType, lineProtocol: string): boolean {
    const point = FTDataFilter.parseLineProtocol(lineProtocol);
    if (point === null) {
      return false;
    }
    return this.isFiltered(dataType, point.measurement, point.tags, point.fields);
  }

  static categoryOf(dataType: DataType): FilterCategory | null {
    if (dataType === DataType.LOG) {
      return FTDataFilter.CATEGORY_LOGGING;
    }
    if (dataType === DataType.RUM_APP || dataType === DataType.RUM_WEBVIEW) {
      return FTDataFilter.CATEGORY_RUM;
    }
    return null;
  }

  private static normalizeCategory(category: string): FilterCategory | null {
    const normalized = category.trim().toLowerCase();
    if (normalized === FTDataFilter.CATEGORY_LOGGING || normalized === FTDataFilter.CATEGORY_RUM) {
      return normalized as FilterCategory;
    }
    return null;
  }

  private static parseConditions(rule: string): Array<FilterExpression> {
    try {
      return new FilterParser(rule).parseConditions();
    } catch (_error) {
      return [];
    }
  }

  private static parseLineProtocol(lineProtocol: string): FTDataFilterPoint | null {
    const firstSpace = FTDataFilter.findUnescapedSpace(lineProtocol, 0);
    if (firstSpace <= 0) {
      return null;
    }
    const metricAndTags = lineProtocol.substring(0, firstSpace);
    const fieldsStart = firstSpace + 1;
    const fieldsEnd = FTDataFilter.findUnescapedSpace(lineProtocol, fieldsStart);
    const rawFields = fieldsEnd === -1
      ? lineProtocol.substring(fieldsStart)
      : lineProtocol.substring(fieldsStart, fieldsEnd);
    if (rawFields.length === 0) {
      return null;
    }

    const metricParts = FTDataFilter.splitUnescaped(metricAndTags, ',', false);
    if (metricParts.length === 0 || metricParts[0].length === 0) {
      return null;
    }
    const tags = new Map<string, FTDataFilterValue>();
    for (let i = 1; i < metricParts.length; i++) {
      const equalsIndex = FTDataFilter.findUnescaped(metricParts[i], '=', false);
      if (equalsIndex <= 0) {
        continue;
      }
      const key = FTDataFilter.unescapeLineProtocol(metricParts[i].substring(0, equalsIndex));
      const value = FTDataFilter.unescapeLineProtocol(metricParts[i].substring(equalsIndex + 1));
      tags.set(key, value);
    }

    const fields = new Map<string, FTDataFilterValue>();
    const fieldParts = FTDataFilter.splitUnescaped(rawFields, ',', true);
    for (let i = 0; i < fieldParts.length; i++) {
      const equalsIndex = FTDataFilter.findUnescaped(fieldParts[i], '=', true);
      if (equalsIndex <= 0) {
        continue;
      }
      const key = FTDataFilter.unescapeLineProtocol(fieldParts[i].substring(0, equalsIndex));
      const value = FTDataFilter.parseFieldValue(fieldParts[i].substring(equalsIndex + 1));
      fields.set(key, value);
    }
    if (fields.size === 0) {
      return null;
    }

    return {
      measurement: FTDataFilter.unescapeLineProtocol(metricParts[0]),
      tags,
      fields
    };
  }

  private static parseFieldValue(value: string): FTDataFilterValue {
    if (value.length >= 2 && value.charAt(0) === '"' && value.charAt(value.length - 1) === '"') {
      return FTDataFilter.unescapeLineProtocol(value.substring(1, value.length - 1));
    }
    const unescapedValue = FTDataFilter.unescapeLineProtocol(value);
    if (unescapedValue === 'true') return true;
    if (unescapedValue === 'false') return false;
    if (/^-?\d+i$/.test(unescapedValue)) {
      return Number(unescapedValue.substring(0, unescapedValue.length - 1));
    }
    if (/^-?\d+(\.\d+)?$/.test(unescapedValue)) {
      return Number(unescapedValue);
    }
    return unescapedValue;
  }

  private static splitUnescaped(value: string, delimiter: string, respectQuotes: boolean): Array<string> {
    const parts: Array<string> = [];
    let start = 0;
    let escaped = false;
    let quoted = false;
    for (let i = 0; i < value.length; i++) {
      const character = value.charAt(i);
      if (escaped) {
        escaped = false;
      } else if (character === '\\') {
        escaped = true;
      } else if (respectQuotes && character === '"') {
        quoted = !quoted;
      } else if (!quoted && character === delimiter) {
        parts.push(value.substring(start, i));
        start = i + 1;
      }
    }
    parts.push(value.substring(start));
    return parts;
  }

  private static findUnescapedSpace(value: string, from: number): number {
    return FTDataFilter.findUnescaped(value, ' ', true, from);
  }

  private static findUnescaped(value: string, target: string, respectQuotes: boolean, from: number = 0): number {
    let escaped = false;
    let quoted = false;
    for (let i = from; i < value.length; i++) {
      const character = value.charAt(i);
      if (escaped) {
        escaped = false;
      } else if (character === '\\') {
        escaped = true;
      } else if (respectQuotes && character === '"') {
        quoted = !quoted;
      } else if (!quoted && character === target) {
        return i;
      }
    }
    return -1;
  }

  private static unescapeLineProtocol(value: string): string {
    let result = '';
    let escaped = false;
    for (let i = 0; i < value.length; i++) {
      const character = value.charAt(i);
      if (escaped) {
        result += character;
        escaped = false;
      } else if (character === '\\') {
        escaped = true;
      } else {
        result += character;
      }
    }
    return escaped ? result + '\\' : result;
  }
}

interface FTDataFilterPoint {
  measurement: string;
  tags: Map<string, FTDataFilterValue>;
  fields: Map<string, FTDataFilterValue>;
}
