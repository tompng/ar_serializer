require_relative 'graphql'

module ArSerializer::TypeScript
  def self.generate_type_definition(*classes)
    types = related_serializer_types classes.flatten
    [
      types.map { |t| data_type_definition t },
      types.map { |t| query_type_definition t }
    ].join "\n"
  end

  def self.query_type_definition(type)
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
      export type #{query_type_name} = keyof (#{base_query_type_name}) | Readonly<(keyof (#{base_query_type_name}))[]> | #{base_query_type_name}
      export interface #{base_query_type_name} {
      #{field_definitions.map { |line| "  #{line}" }.join("\n")}
      }
    TYPE
  end

  def self.data_type_definition(type)
    field_definitions = []
    type.fields.each do |field|
      field_definitions << "#{field.name}: #{field.type.ts_type}"
    end
    field_definitions << "_meta?: { name: '#{type.name}'; query: Type#{type.name}QueryBase }"
    <<~TYPE
      export interface Type#{type.name} {
      #{field_definitions.map { |line| "  #{line}" }.join("\n")}
      }
    TYPE
  end

  def self.related_serializer_types(classes)
    types_set = {}
    classes.each do |klass|
      type = ArSerializer::GraphQL::TypeClass.from klass
      type.collect_types types_set
    end
    types_set.keys.grep(ArSerializer::GraphQL::TypeClass).sort_by(&:name)
  end
end
