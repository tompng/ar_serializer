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
    finfo = all_classes.map { |k| data_type_object_definition k }.to_h
    finfo_type = '{ [key: string]: { [key: string]: (true | DataTypeName) } }'
    <<~CODE
      type DataTypeName = #{finfo.keys.map(&:to_json).join(' | ')}
      const definitions: #{finfo_type} = #{finfo.to_json}
      #{QueryBuilderScript}
    CODE
  end

  def self.query_type_definition(klass)
    type = ArSerializer::GraphQL::TypeClass.from klass
    field_definitions = type.fields.map do |field|
      if field.type.association_type?
        of_type = field.type.association_type
        qname = "Type#{of_type.name}Query"
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
      export type #{base_query_type_name} = {
      #{field_definitions.map { |line| "  #{line}" }.join("\n")}
      }
    TYPE
  end

  def self.data_type_object_definition(klass)
    type = ArSerializer::GraphQL::TypeClass.from klass
    field_definitions = type.fields.map do |field|
      if field.type.association_type?
        [field.name, field.type.association_type.name]
      else
        [field.name, true]
      end
    end
    [type.name, field_definitions.to_h]
  end

  def self.data_type_definition(klass)
    type = ArSerializer::GraphQL::TypeClass.from klass
    field_definitions = []
    type.fields.each do |field|
      field_definitions << "#{field.name}?: #{field.type.ts_type}"
      next if field.args.empty?
      field_definitions << "#{field.name}Params?: #{field.args_ts_type}"
    end
    field_definitions << "_meta?: { name: '#{type.name}'; query: Type#{type.name}QueryBase }"
    <<~TYPE
      export type Type#{type.name} = {
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
    type Meta = { query: {}; name: string }
    type DataTypeBase = { _meta?: Meta }
    export function buildQuery<DataType extends DataTypeBase>(
      name: (DataType['_meta'] & Meta)['name'],
      data: DataType
    ): (DataType['_meta'] & Meta)['query'] {
      const defs = definitions[name]
      const query: { [key: string]: any } = {}
      for (const fieldName in data) {
        const paramsPattern = /Params$/
        if (fieldName.match(paramsPattern) && data[fieldName.replace(paramsPattern, '')]) continue
        const params = data[fieldName + 'Params']
        let fieldValue = data[fieldName]
        const fieldType = defs[fieldName]
        if (!fieldType) continue
        if (fieldType === true) {
          query[fieldName] = params ? { params } : true
          continue
        }
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
