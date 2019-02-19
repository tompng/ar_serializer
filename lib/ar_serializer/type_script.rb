require_relative 'graphql'

module ArSerializer::TypeScript
  def self.generate_type_definition(*classes)
    all_classes = all_related_classes classes.flatten
    [
      all_classes.map { |k| data_type_definition k },
      all_classes.map { |k| query_type_definition k }
    ].join "\n"
  end

  def self.generate_query_builder(*classes)
    all_classes = all_related_classes classes.flatten
    dinfo = all_classes.map { |k| data_type_object_definition k }
    <<~CODE
      export const definitions = {
      #{dinfo.join(",\n").lines.map { |l| "  #{l}" }.join}
      }
      #{QueryBuilderScript}
    CODE
  end

  def self.query_type_definition(klass)
    type = ArSerializer::GraphQL::TypeClass.from klass
    field_definitions = type.fields.map do |field|
      association_type = field.type.association_type
      if association_type
        qname = "Type#{association_type.name}Query"
        if field.args.empty?
          "#{field.name}?: true | #{qname} | { as?: string; attributes?: #{qname} }"
        else
          "#{field.name}?: true | #{qname} | { as?: string; params: #{field.args_ts_type}; attributes?: #{qname} }"
        end
      else
        "#{field.name}?: true | { as: string }"
      end
    end
    field_definitions << "'*'?: true"
    query_type_name = "Type#{type.name}Query"
    base_query_type_name = "Type#{type.name}QueryBase"
    <<~TYPE
      export type #{query_type_name} = keyof (#{base_query_type_name}) | (keyof (#{base_query_type_name}))[] | #{base_query_type_name}
      export interface #{base_query_type_name} {
      #{field_definitions.map { |line| "  #{line}" }.join("\n")}
      }
    TYPE
  end

  def self.data_type_object_definition(klass)
    type = ArSerializer::GraphQL::TypeClass.from klass
    fields = {}
    children = {}
    type.fields.map do |field|
      association_type = field.type.association_type
      if association_type
        children[field.name] = association_type
      else
        fields[field.name] = field.type
      end
    end
    <<~DEFS.strip
      #{type.name}: {
        fields: {
      #{fields.map { |k, t| "    #{k}: #{t.sample.to_json} as #{t.ts_type}" }.join(",\n")}
        },
        children: {
      #{children.map { |k, t| "    #{k}: #{t.name.to_json}" }.join(",\n")}
        }
      }
    DEFS
  rescue => e
    binding.pry
  end

  def self.data_type_definition(klass)
    type = ArSerializer::GraphQL::TypeClass.from klass
    field_definitions = []
    params = []
    type.fields.each do |field|
      field_definitions << "#{field.name}?: #{field.type.ts_type}"
      params << "#{field.name}?: #{field.args_ts_type}" unless field.args.empty?
    end
    unless params.empty?
      field_definitions << '_params?: {'
      params.each { |p| field_definitions << "  #{p}" }
      field_definitions << '}'
    end
    field_definitions << "_meta?: { name: '#{type.name}'; query: Type#{type.name}QueryBase }"
    <<~TYPE
      export interface Type#{type.name} {
      #{field_definitions.map { |line| "  #{line}" }.join("\n")}
      }
    TYPE
  end

  def self.all_related_classes(classes)
    types_set = {}
    classes.each do |klass|
      type = ArSerializer::GraphQL::TypeClass.from klass
      type.collect_types types_set
    end
    types_set.keys.grep(Class).sort_by { |k| k.name.delete ':' }
  end

  QueryBuilderScript = <<~CODE
    interface Meta { query: {}; name: string }
    interface DataTypeBase { _meta?: Meta, _params?: { [key: string]: any } }
    export function buildQuery<DataType extends DataTypeBase>(
      name: (DataType['_meta'] & Meta)['name'],
      data: DataType
    ): (DataType['_meta'] & Meta)['query'] {
      const defs = definitions[name as any]
      if (!defs) return {} as any
      const query: { [key: string]: any } = {}
      for (const fieldName in data) {
        const params = data._params && data._params[fieldName]
        if (defs.fields[fieldName] !== undefined) {
          query[fieldName] = params ? { params } : true
          continue
        }
        const fieldType = defs.children[fieldName]
        if (!fieldType) continue
        let fieldValue = data[fieldName]
        if (fieldValue instanceof Array) {
          if (fieldValue.length === 0) {
            query[fieldName] = true
            continue
          }
          fieldValue = fieldValue[0]
        }
        const subQuery = buildQuery(fieldType as any, fieldValue)
        if (params) {
          query[fieldName] = { params, attributes: subQuery }
        } else {
          query[fieldName] = subQuery
        }
      }
      return query as any
    }
  CODE
end
