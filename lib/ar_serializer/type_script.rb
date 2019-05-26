require_relative 'graphql'

module ArSerializer::TypeScript
  def self.generate_type_definition(*classes)
    types = related_serializer_types classes.flatten
    [
      'type NonAliasQuery = true | false | string | string[] | ({ field?: undefined } & { [key: string]: any })',
      types.map { |t| data_type_definition t },
      types.map { |t| query_type_definition t }
    ].join "\n"
  end

  FieldInfo = Struct.new :name, :params_required?, :params_type, :query_type, :sub_query_params

  def self.query_type_definition(type)
    field_definitions = type.fields.map do |field|
      association_type = field.type.association_type
      query_type = "Type#{association_type.name}Query" if association_type
      params_type = field.args_ts_type unless field.args.empty?
      params_required = field.args_required?
      attrs = []
      attrs << "query?: #{query_type}" if query_type
      attrs << "params#{'?' unless params_required}: #{params_type}" if params_type
      sub_query_params = attrs
      FieldInfo.new field.name, params_required, params_type, query_type, sub_query_params
    end
    accept_wildcard = !field_definitions.any?(&:params_required?)
    query_type_name = "Type#{type.name}Query"
    standalone_fields_name = "Type#{type.name}StandaloneFields"
    alias_query_type_name = "Type#{type.name}AliasFieldQuery"
    base_query_type_name = "Type#{type.name}QueryBase"
    standalone_fields_definition = field_definitions.reject(&:params_required?).map do |info|
      "'#{info.name}'"
    end.join(' | ')
    standalone_fields_definition += " | '*'" if accept_wildcard
    alias_query_type_definition = field_definitions.map do |info|
      attrs = ["field: '#{info.name}'", *info.sub_query_params].join('; ')
      "  | { #{attrs} }\n"
    end.join
    base_query_type_definition = field_definitions.map do |info|
      types = []
      unless info.params_required?
        types << true
        types << info.query_type if info.query_type
      end
      types << "{ field: never; #{info.sub_query_params.join('; ')} }" unless info.sub_query_params.empty?
      "  #{info.name}: #{types.join(' | ')}"
    end.join("\n")
    base_query_type_definition += "\n  '*': true" if accept_wildcard
    <<~TYPE
      export type #{query_type_name} = #{standalone_fields_name} | Readonly<#{standalone_fields_name}[]>
        | (
          { [key in keyof #{base_query_type_name}]?: key extends '*' ? true : #{base_query_type_name}[key] | #{alias_query_type_name} }
          & { [key: string]: #{alias_query_type_name} | NonAliasQuery }
        )
      export type #{standalone_fields_name} = #{standalone_fields_definition.presence || 'never'}
      export type #{alias_query_type_name} =
      #{alias_query_type_definition.presence || 'never'}
      export interface #{base_query_type_name} {
      #{base_query_type_definition}
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
