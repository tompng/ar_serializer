module ArSerializer::GraphQL
  def self.definition(schema_klass, use: nil)
    ArSerializer::Serializer.with_namespaces(use) { _definition schema_klass }
  end
  def self._definition(schema_klass)
    type_name = lambda do |type|
      if type.nil?
        'Any'
      elsif type.is_a?(Array)
        "[#{type_name.call type.first}]"
      elsif %i[int int! float float! boolean boolean! string string!].include? type
        type.to_s.camelize
      elsif type.is_a?(Class) && type < ArSerializer::Serializable
        type.name.delete ':'
      else
        raise "invalid type: #{type.class}: #{type}"
      end
    end
    extract_schema = lambda do |klass|
      fields = []
      types = []
      klass._serializer_field_keys.each do |name|
        field = klass._serializer_field_info name
        type = field.type
        types << (type.is_a?(Array) ? type.first : type)
        arguments = field.arguments
        unless arguments.empty?
          arg_types = arguments.map { |key, req| "#{key}: Any#{req ? '!' : ''}"  }
          arg = "(#{arg_types.join ', '})"
        end
        fields << "  #{name}#{arg}: #{type_name.call type}"
      end
      schema = ["type #{type_name.call klass} {", fields, '}'].join "\n"
      [schema, types]
    end
    defined_types = {}
    types = [schema_klass]
    definitions = []
    definitions << 'scalar Any'
    until types.empty?
      type = types.shift
      next if defined_types[type]
      next unless type.is_a?(Class) && type < ArSerializer::Serializable
      defined_types[type] = true
      schema, sub_types = extract_schema.call type
      definitions << schema
      types += sub_types
    end
    <<~SCHEMA
      schema {
        query: #{type_name.call schema_klass}
      }

      #{definitions.join "\n\n"}
    SCHEMA
  end

  def self.serialize(schema, query, use: nil)
    document = GraphQL::Language::Parser.parse query, filename: nil, tracer: GraphQL::Tracing::NullTracer
    parse_arguments = lambda do |arguments|
      arguments.map { |arg| [arg.name, arg.value] }.to_h
    end
    parse_query = lambda do |selections|
      selections.index_by(&:name).transform_values do |selection|
        {
          attributes: parse_query.call(selection.selections),
          params: parse_arguments.call(selection.arguments),
          as: selection.alias
        }.compact
      end
    end
    parsed_query = parse_query.call document.definitions.first.selections
    {
      data: ArSerializer::Serializer.serialize(schema, parsed_query, use: use)
    }
  end
end
