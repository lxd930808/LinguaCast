/**
 * Minimal JSON Schema (draft 2020-12 subset) validator for contract fixture
 * tests. Supports only the keywords our own schemas use:
 * type, const, enum, required, properties, additionalProperties, items,
 * minItems, minLength, maxLength, minimum, maximum, pattern, anyOf, format
 * (date-time/uri checked loosely). No external dependencies by design.
 */

export interface SchemaNode {
  $ref?: string;
  definitions?: Record<string, SchemaNode>;
  type?: string | string[];
  const?: unknown;
  enum?: unknown[];
  required?: string[];
  properties?: Record<string, SchemaNode>;
  additionalProperties?: boolean | SchemaNode;
  items?: SchemaNode;
  minItems?: number;
  minLength?: number;
  maxLength?: number;
  minimum?: number;
  maximum?: number;
  pattern?: string;
  anyOf?: SchemaNode[];
  format?: string;
}

export function validate(schema: SchemaNode, value: unknown, path = '$', root?: SchemaNode): string[] {
  const errors: string[] = [];
  const rootSchema = root ?? schema;

  if (schema.$ref) {
    const refPrefix = '#/definitions/';
    if (!schema.$ref.startsWith(refPrefix)) {
      return [`${path}: unsupported $ref ${schema.$ref}`];
    }
    const target = rootSchema.definitions?.[schema.$ref.slice(refPrefix.length)];
    if (!target) return [`${path}: unknown $ref ${schema.$ref}`];
    return validate(target, value, path, rootSchema);
  }

  if (schema.anyOf) {
    const matched = schema.anyOf.some((branch) => validate(branch, value, path, rootSchema).length === 0);
    if (!matched) errors.push(`${path}: does not match any allowed branch`);
    return errors;
  }

  if (schema.const !== undefined && value !== schema.const) {
    errors.push(`${path}: expected const ${JSON.stringify(schema.const)}`);
    return errors;
  }
  if (schema.enum && !schema.enum.some((candidate) => candidate === value)) {
    errors.push(`${path}: expected one of ${schema.enum.map((c) => JSON.stringify(c)).join(', ')}, got ${JSON.stringify(value)}`);
    return errors;
  }

  if (schema.type) {
    const allowed = Array.isArray(schema.type) ? schema.type : [schema.type];
    const ok = allowed.some((t) => typeMatches(t, value));
    if (!ok) {
      errors.push(`${path}: expected type ${allowed.join('|')}, got ${describeType(value)}`);
      return errors;
    }
  }

  if (typeof value === 'string') {
    if (schema.minLength !== undefined && value.length < schema.minLength) {
      errors.push(`${path}: shorter than minLength ${schema.minLength}`);
    }
    if (schema.maxLength !== undefined && value.length > schema.maxLength) {
      errors.push(`${path}: longer than maxLength ${schema.maxLength}`);
    }
    if (schema.pattern && !new RegExp(schema.pattern).test(value)) {
      errors.push(`${path}: does not match pattern ${schema.pattern}`);
    }
    if (schema.format === 'date-time' && Number.isNaN(Date.parse(value))) {
      errors.push(`${path}: not a valid date-time`);
    }
    if (schema.format === 'uri') {
      try {
        new URL(value);
      } catch {
        errors.push(`${path}: not a valid URI`);
      }
    }
  }

  if (typeof value === 'number') {
    if (schema.minimum !== undefined && value < schema.minimum) {
      errors.push(`${path}: below minimum ${schema.minimum}`);
    }
    if (schema.maximum !== undefined && value > schema.maximum) {
      errors.push(`${path}: above maximum ${schema.maximum}`);
    }
    if (schema.type === 'integer' && !Number.isInteger(value)) {
      errors.push(`${path}: not an integer`);
    }
  }

  if (Array.isArray(value)) {
    if (schema.minItems !== undefined && value.length < schema.minItems) {
      errors.push(`${path}: fewer than minItems ${schema.minItems}`);
    }
    if (schema.items) {
      value.forEach((item, index) => {
        errors.push(...validate(schema.items as SchemaNode, item, `${path}[${index}]`, rootSchema));
      });
    }
  }

  if (value !== null && typeof value === 'object' && !Array.isArray(value)) {
    const obj = value as Record<string, unknown>;
    for (const key of schema.required ?? []) {
      if (!(key in obj)) errors.push(`${path}: missing required property ${key}`);
    }
    const properties = schema.properties ?? {};
    for (const [key, subschema] of Object.entries(properties)) {
      if (key in obj) {
        errors.push(...validate(subschema, obj[key], `${path}.${key}`, rootSchema));
      }
    }
    if (schema.additionalProperties === false) {
      for (const key of Object.keys(obj)) {
        if (!(key in properties)) errors.push(`${path}: unexpected additional property ${key}`);
      }
    } else if (schema.additionalProperties && typeof schema.additionalProperties === 'object') {
      for (const key of Object.keys(obj)) {
        if (!(key in properties)) {
          errors.push(...validate(schema.additionalProperties, obj[key], `${path}.${key}`, rootSchema));
        }
      }
    }
  }

  return errors;
}

function typeMatches(type: string, value: unknown): boolean {
  switch (type) {
    case 'null':
      return value === null;
    case 'string':
      return typeof value === 'string';
    case 'number':
      return typeof value === 'number';
    case 'integer':
      return typeof value === 'number' && Number.isInteger(value);
    case 'boolean':
      return typeof value === 'boolean';
    case 'array':
      return Array.isArray(value);
    case 'object':
      return value !== null && typeof value === 'object' && !Array.isArray(value);
    default:
      return false;
  }
}

function describeType(value: unknown): string {
  if (value === null) return 'null';
  if (Array.isArray(value)) return 'array';
  return typeof value;
}
