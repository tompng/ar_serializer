module ArSerializer::GraphQL
  def self.definition(schema_klass, use: nil)
    ArSerializer::Serializer.with_namespaces(use) { _definition schema_klass }
  end
  def self._definition(schema_klass)
    type_name = lambda do |type|
      if type.nil?
        'Any'
      elsif type.is_a?(Hash) && type.values == [:required]
        type_name.call(type.keys.first).gsub(/!?$/, '!')
      elsif type.is_a?(Array) && type.size == 1
        "[#{type_name.call type.first}]"
      elsif %i[any any! int int! float float! boolean boolean! string string!].include? type
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
          arg_types = arguments.map { |key, arg_type| "#{key}: #{type_name.call arg_type}"  }
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

  def self.serialize(schema, gql_query, *args)
    query = ArSerializer::GraphQL::QueryParser.parse gql_query
    { data: ArSerializer::Serializer.serialize(schema, query, *args) }
  end
end

module ArSerializer::GraphQL::QueryParser
  def self.parse query
    chars = query.chars
    consume_blank = lambda do
      chars.shift while chars.first == ' ' || chars.first == "\n"
    end
    consume_space = lambda do
      chars.shift while chars.first == ' '
    end
    consume_pattern = lambda do |pattern|
      return unless chars.take(pattern.size).join == pattern
      chars.shift pattern.size
      true
    end
    parse_name = lambda do
      name = ''
      name << chars.shift while chars.first && chars.first =~ /[a-zA-Z0-9_]/
      name unless name.empty?
    end
    parse_name_alias = lambda do
      name = parse_name.call
      return unless name
      consume_space.call
      if consume_pattern.call ':'
        consume_space.call
        [parse_name.call, name]
      else
        name
      end
    end
    parse_arg_value = lambda do
      s = []
      mode = []
      loop do
        c = chars.first
        case mode.last
        when '"'
          if c == '"'
            mode.pop
          elsif c == '\\'
            mode << '\\'
          end
        when '\\'
          mode.pop
        else
          break if c == ')'
          break if mode.empty? && c == ','
          if '"[{'.include? c
            mode << c
          elsif ']}'.include? c
            mode.pop
          elsif c == '"'
            modes << '"'
          end
        end
        s << chars.shift
      end
      raise unless mode.empty?
      JSON.parse s.join
    end
    parse_args = lambda do
      consume_space.call
      return unless consume_pattern.call '('
      args = {}
      loop do
        consume_blank.call
        name = parse_name.call
        break unless name
        raise unless consume_pattern.call ':'
        consume_blank.call
        args[name] = parse_arg_value.call
        consume_blank.call
        break unless consume_pattern.call ','
      end
      consume_blank.call
      raise unless consume_pattern.call ')'
      args
    end
    parse_fields = nil
    parse_field = lambda do
      name, alias_name = parse_name_alias.call
      return unless name
      consume_space.call
      args = parse_args.call
      consume_space.call
      fields = parse_fields.call
      [name, { as: alias_name, params: args, attributes: fields }.compact]
    end
    parse_fields = lambda do
      consume_blank.call
      return unless consume_pattern.call '{'
      consume_blank.call
      fields = {}
      loop do
        name, field = parse_field.call
        break unless name
        fields[name] = field
        consume_blank.call
      end
      raise unless consume_pattern.call '}'
      fields
    end
    consume_blank.call
    fields = parse_fields.call
    consume_blank.call
    raise unless chars.empty?
    fields
  end

  graphql_available = begin
    require 'graphql'
    true
  rescue LoadError
    false
  end
  if graphql_available
    def self.parse(query)
      document = GraphQL::Language::Parser.parse query
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
      parse_query.call document.definitions.first.selections
    end
  end
end
