module ArSerializer::GraphQL
  class ArgClass
    include ::ArSerializer::Serializable
    attr_reader :name, :type
    def initialize(name, type)
      @optional = name.to_s.end_with? '?' # TODO: refactor
      @name = name.to_s.delete '?'
      @type = type
    end
    serializer_field :name
    serializer_field :type, except: :fields
    serializer_field(:defaultValue) { nil }
    serializer_field(:description) { "#{'Optional: ' if @optional}#{type.description}" }
  end

  class FieldClass
    include ::ArSerializer::Serializable
    attr_reader :name, :field
    def initialize(name, field)
      @name = name
      @field = field
    end

    def args
      arguments = field.arguments_type
      return [] unless arguments.is_a?(HashTypeClass)

      arguments.type.map do |key, type|
        ArgClass.new key, type
      end
    end

    def type
      TypeClass.from field.type, field.only, field.except
    end

    def collect_types(types)
      field.arguments_type.collect_types types
      type.collect_types types
    end

    def args_required?
      arguments_type = field.arguments_type
      case arguments_type
      when TSTypeClass
        true
      when HashTypeClass
        arguments_type.type.any? do |k, v|
          !k.end_with?('?') && !v.is_a?(OptionalTypeClass)
        end
      else
        false
      end
    end

    def args_ts_type
      field.arguments_type.ts_type
    end

    serializer_field :name, :args
    serializer_field :type, except: :fields
    serializer_field(:isDeprecated) { false }
    serializer_field(:description) { type.description }
    serializer_field(:deprecationReason) { nil }
  end

  class SchemaClass
    include ::ArSerializer::Serializable
    attr_reader :klass, :query_type
    def initialize(klass)
      @klass = klass
      @query_type = SerializableTypeClass.new klass
    end

    def collect_types
      types = {}
      klass._serializer_field_keys.each do |name|
        fc = FieldClass.new name, klass._serializer_field_info(name)
        fc.collect_types types
      end
      type_symbols, type_classes = types.keys.partition { |t| t.is_a? Symbol }
      type_classes << TypeClass.from(klass)
      [type_symbols.sort, type_classes.sort_by(&:name)]
    end

    def types
      types_symbols, klass_types = collect_types
      types_symbols.map { |t| ScalarTypeClass.new t } + klass_types
    end

    serializer_field(:mutationType) { nil }
    serializer_field(:subscriptionType) { nil }
    serializer_field(:directives) { [] }
    serializer_field :types, :queryType
  end

  class TypeClass
    include ::ArSerializer::Serializable
    attr_reader :type
    def initialize(type)
      @type = type
    end

    class InvalidType < StandardError; end

    def collect_types(types); end

    def description = ts_type

    def name; end

    def of_type; end

    def fields; end

    def ts_type; end

    def association_type; end

    serializer_field :kind, :name, :description, :fields
    serializer_field :ofType, except: :fields
    serializer_field(:interfaces) { [] }
    %i[inputFields enumValues possibleTypes].each do |name|
      serializer_field(name) { nil }
    end

    def self.from(type, only = nil, except = nil)
      type = [type[0...-1].to_sym, nil] if type.is_a?(Symbol) && type.to_s.end_with?('?')
      type = [type[0...-1], nil] if type.is_a?(String) && type.end_with?('?') # ??
      case type
      when Class
        raise InvalidType, "#{type} must include ArSerializer::Serializable" unless type.ancestors.include? ArSerializer::Serializable

        SerializableTypeClass.new type, only, except
      when :number, :int, :float, :string, :boolean, :any, :unknown
        ScalarTypeClass.new type
      when String, Numeric, true, false, nil
        ScalarTypeClass.new type
      when Array
        if type.size == 1
          ListTypeClass.new from(type.first, only, except)
        elsif type.size == 2 && type.last.nil?
          OptionalTypeClass.new from(type.first, only, except)
        else
          OrTypeClass.new type.map {|v| from(v, only, except) }
        end
      when Hash
        HashTypeClass.new type.transform_values {|v| from(v, only, except) }
      when ArSerializer::TSType
        TSTypeClass.new type.type
      else
        raise InvalidType, "Invalid type: #{type}"
      end
    end
  end

  class TSTypeClass < TypeClass
    def initialize(type)
      @type = type
    end

    def kind = 'SCALAR'

    def name = :other

    def collect_types(types)
      types[:other] = true
    end

    def gql_type = 'SCALAR'

    def ts_type = @type
  end

  class ScalarTypeClass < TypeClass
    def initialize(type)
      @type = type
    end

    def kind = 'SCALAR'

    def name
      case type
      when String, :string
        :string
      when Integer, :int
        :int
      when Float, :float
        :float
      when true, false, :boolean
        :boolean
      when :other
        :other
      when :unknown
        :unknown
      else
        :any
      end
    end

    def collect_types(types)
      types[name] = true
    end

    def gql_type = type

    def ts_type
      case type
      when :int, :float
        'number'
      when :string, :number, :boolean, :unknown
        type.to_s
      when Symbol
        'any'
      else
        type.to_json
      end
    end
  end

  class HashTypeClass < TypeClass
    def kind = 'SCALAR'

    def name = :other

    def collect_types(types)
      types[:other] = true
      type.values.each do |v|
        v.collect_types(types)
      end
    end

    def association_type
      type.values.each do |v|
        t = v.association_type
        return t if t
      end
      nil
    end

    def gql_type = 'OBJECT'

    def ts_type
      return 'Record<string, never>' if type.empty?

      fields = type.map do |key, value|
        k = key.to_s == '*' ? '[key: string]' : key
        "#{k}: #{value.ts_type}"
      end
      "{ #{fields.join('; ')} }"
    end

    def to_gql_args
      type.map do |key, type|
        ArgClass.new key, type
      end
    end
  end

  class SerializableTypeClass < TypeClass
    attr_reader :only, :except

    def initialize(type, only = nil, except = nil)
      super type
      @only = only
      @except = except
    end

    def field_only
      [*only].map(&:to_s)
    end

    def field_except
      [*except].map(&:to_s)
    end

    def kind = 'OBJECT'

    def name
      name_segments = [type.name.delete(':')]
      unless field_only.empty?
        name_segments << 'Only'
        name_segments << field_only.map(&:camelize)
      end
      unless field_except.empty?
        name_segments << 'Except'
        name_segments << field_except.map(&:camelize)
      end
      name_segments.join
    end

    def fields
      keys = type._serializer_field_keys - ['__schema'] - field_except
      keys = field_only & keys unless field_only.empty?
      keys.map do |name|
        FieldClass.new name, type._serializer_field_info(name)
      end
    end

    def collect_types(types)
      return if types[self]
      types[self] = true
      fields.each { |field| field.collect_types types }
    end

    def association_type = self

    def gql_type = name

    def ts_type = "Type#{name}"

    def eql?(t)
      self.class == t.class && self.compare_elements == t.compare_elements
    end

    def == t
      eql? t
    end

    def compare_elements
      [type, field_only, field_except]
    end

    def hash
      compare_elements.hash
    end
  end

  class OptionalTypeClass < TypeClass
    def kind = type.kind

    def name = type.name

    def of_type = type

    def association_type = type.association_type

    def collect_types(types)
      type.collect_types types
    end

    def gql_type = type.gql_type

    def ts_type = "(#{type.ts_type} | null)"
  end

  class OrTypeClass < TypeClass
    def kind = 'OBJECT'

    def name = :other

    def of_types = type

    def collect_types(types)
      types[:other] = true
      type.map { |t| t.collect_types types }
    end

    def gql_type = kind

    def ts_type = "(#{type.map(&:ts_type).join(' | ')})"
  end

  class ListTypeClass < TypeClass
    def kind = 'LIST'

    def name = 'LIST'

    def of_type = type

    def collect_types(types)
      type.collect_types types
    end

    def association_type = type.association_type

    def gql_type = "[#{type.gql_type}]"

    def ts_type = "(#{type.ts_type} [])"
  end
end
