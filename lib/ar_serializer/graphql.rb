module ArSerializer::GraphQL
  class NamedObject
    include ::ArSerializer::Serializable
    attr_reader :name
    def initialize(name)
      @name = name
    end
    serializer_field :name
  end
  class ArgClass
    include ::ArSerializer::Serializable
    attr_reader :name, :type
    def initialize(name, type)
      @name = name
      @type = TypeClass.from type
    end
    serializer_field :name
    serializer_field :type, except: :fields
    serializer_field(:defaultValue) { nil }
    serializer_field(:description) { nil }
  end
  class FieldClass
    include ::ArSerializer::Serializable
    attr_reader :name, :field
    def initialize(name, field)
      @name = name
      @field = field
    end

    def args
      field.arguments.map do |key, type|
        ArgClass.new key, type
      end
    end

    def type
      TypeClass.from field.type
    end

    def collect_types(types)
      args.each { |arg| arg.type.collect_types types }
      type.collect_types types
    end

    serializer_field :name, :args
    serializer_field :type, except: :fields
    %i[description isDeprecated deprecationReason].each do |name|
      serializer_field(name) { nil }
    end
  end

  class SchemaClass
    include ::ArSerializer::Serializable
    attr_reader :klass
    def initialize(klass)
      @klass = klass
    end

    def collect_types
      types = {}
      klass._serializer_field_keys.each do |name|
        fc = FieldClass.new name, klass._serializer_field_info(name)
        fc.collect_types types
      end
      strings, klasses = types.keys.partition { |t| t.is_a? String }
      klasses << klass
      strings.sort + klasses.sort_by(&:name)
    end

    def types
      collect_types.map { |type| TypeClass.from type }
    end

    def name
      klass.name.delete ':'
    end
    serializer_field(:queryType) { NamedObject.new name }
    serializer_field(:mutationType) { nil }
    serializer_field(:subscriptionType) { nil }
    serializer_field(:directives) { [] }
    serializer_field :types
  end

  class TypeClass
    include ::ArSerializer::Serializable
    include ::ArSerializer
    attr_reader :type
    def initialize(type)
      @type = type
    end

    def collect_types(types); end

    def description
      ''
    end

    def name; end

    def of_type; end

    def fields; end

    serializer_field :kind, :name, :description, :fields
    serializer_field :ofType, except: :fields
    serializer_field(:interfaces) { [] }
    %i[inputFields enumValues possibleTypes].each do |name|
      serializer_field(name) { nil }
    end

    def self.from(type)
      type = type.to_s if type.is_a?(Symbol)
      type = type.capitalize if type.is_a?(String)
      type = { type[0...-1] => :required } if type.is_a?(String) && type.ends_with?('!')
      type = 'Any' if type.is_a?(String) && type.empty?
      case type
      when Class
        SerializableTypeClass.new type
      when String
        ScalarTypeClass.new type
      when Array
        ListTypeClass.new type.first
      when Hash
        NonNullTypeClass.new type.keys.first
      when nil
        ScalarTypeClass.new 'Any'
      end
    end
  end

  class ScalarTypeClass < TypeClass
    def kind
      'SCALAR'
    end

    def name
      type
    end

    def collect_types(types)
      types[name] = true
    end

    def inspect
      type
    end
  end

  class SerializableTypeClass < TypeClass
    def kind
      'OBJECT'
    end

    def name
      type.name.delete ':'
    end

    def fields
      (type._serializer_field_keys - ['__schema']).map do |name|
        FieldClass.new name, type._serializer_field_info(name)
      end
    end

    def collect_types(types)
      return if types[type]
      types[type] = true
      fields.each { |field| field.collect_types types }
    end

    def inspect
      name
    end
  end

  class ListTypeClass < TypeClass
    def kind
      'LIST'
    end

    def of_type
      TypeClass.from type
    end

    def collect_types(types)
      of_type.collect_types types
    end

    def inspect
      "[#{of_type.inspect}]"
    end
  end

  class NonNullTypeClass < TypeClass
    def kind
      'LIST'
    end

    def of_type
      TypeClass.from type
    end

    def collect_types(types)
      of_type.collect_types types
    end

    def inspect
      "#{of_type.inspect}!"
    end
  end

  def self.definition(klass, use: nil)
    ArSerializer::Serializer.with_namespaces(use) { _definition klass }
  end

  def self._definition(klass)
    schema = SchemaClass.new(klass)
    definitions = schema.types.map do |type|
      next "scalar #{type.name}" if type.is_a? ScalarTypeClass
      fields = type.fields.map do |field|
        field.name
        args = field.args.map { |arg| "#{arg.name}: #{arg.type.inspect}" }
        args_exp = "(#{args.join(', ')})" unless args.empty?
        "  #{field.name}#{args_exp}: #{field.type.inspect}"
      end
      <<~TYPE
        type #{type.name} {
        #{fields.join("\n")}
        }
      TYPE
    end
    <<~SCHEMA
      schema {
        query: #{schema.name}
      }

      #{definitions.map(&:strip).join("\n\n")}
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
    parse_arg_fields = nil
    parse_arg_value = lambda do
      consume_blank.call
      case chars.first
      when '"'
        chars.shift
        s = ''
        loop do
          if chars.first == '\\'
            s << chars.shift
            s << chars.shift
          elsif chars.first == '"'
            break
          else
            s << chars.shift
          end
        end
        chars.shift
        JSON.parse %("#{s}")
      when '['
        chars.shift
        result = []
        loop do
          value = parse_arg_value.call
          consume_pattern.call ','
          break if value == :none
          result << value
        end
        raise unless consume_pattern.call ']'
        result
      when '{'
        chars.shift
        result = parse_arg_fields.call
        raise unless consume_pattern.call '}'
        result
      when /[0-9+\-]/
        s = ''
        s << chars.shift while chars.first.match?(/[0-9.e+\-]/)
        s.match?(/\.|e/) ? s.to_f : s.to_i
      else
        :none
      end
    end

    parse_arg_fields = lambda do
      consume_blank.call
      result = {}
      loop do
        name = parse_name.call
        break unless name
        consume_blank.call
        raise unless consume_pattern.call ':'
        consume_blank.call
        value = parse_arg_value.call
        raise if value == :none
        result[name] = value
        consume_blank.call
        consume_pattern.call ','
        consume_blank.call
      end
      consume_blank.call
      result
    end

    parse_args = lambda do
      return unless consume_pattern.call '('
      args = parse_arg_fields.call
      raise unless consume_pattern.call ')'
      return args
    end
    parse_fields = nil
    parse_field = lambda do
      if chars[0,3].join == '...'
        3.times { chars.shift }
        name = parse_name.call
        return ['...' + name, { fragment: name }]
      end
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
        consume_blank.call
        break unless name
        fields[name] = field
      end
      raise unless consume_pattern.call '}'
      fields
    end
    parse_definition = lambda do
      consume_blank.call
      definition_types = ''
      definition_types << chars.shift while chars.first&.match?(/[a-zA-Z0-9_\t ]/)
      fields = parse_fields.call
      consume_blank.call
      return unless fields
      type, *args = definition_types.split
      type ||= 'query'
      { type: type, args: args, fields: fields }
    end
    definitions = []
    loop do
      definition = parse_definition.call
      break unless definition
      definitions << definition
    end
    raise unless chars.empty?

    query = definitions.find { |definition| definition[:type] == 'query' }
    fragments = definitions.select { |definition| definition[:type] == 'fragment' }
    fragments_by_name = fragments.map { |frag| [frag[:args].first, frag] }.to_h

    embed_fragment = nil
    extract_fragment = lambda do |fragment|
      raise if fragment[:state] == :start
      return if fragment[:state] == :done
      fragment[:state] = :start
      fragment[:fields] = embed_fragment.call fragment[:fields]
      fragment[:state] = :done
    end

    embed_fragment = lambda do |fields|
      output = {}
      fields.each do |key, value|
        if value.is_a?(Hash) && value[:fragment]
          fragment = fragments_by_name[value[:fragment]]
          extract_fragment.call fragment
          output.update fragment[:fields]
        else
          output[key] = value
          value[:attributes] = embed_fragment.call value[:attributes] if value[:attributes]
        end
      end
      output
    end
    embed_fragment.call query[:fields]
  end
end
