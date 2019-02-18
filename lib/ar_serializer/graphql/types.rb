module ArSerializer::GraphQL
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
    serializer_field(:description) { type.description }
  end

  class FieldClass
    include ::ArSerializer::Serializable
    attr_reader :name, :field
    def initialize(name, field)
      @name = name
      @field = field
    end

    def args
      return [] if field.arguments == :any
      field.arguments.map do |key, type|
        ArgClass.new key, type
      end
    end

    def type
      TypeClass.from field.type
    end

    def collect_types(types)
      types[:any] = true if field.arguments == :any
      args.each { |arg| arg.type.collect_types types }
      type.collect_types types
    end

    def args_ts_type
      arg_types = field.arguments.map do |key, type|
        "#{key}: #{TypeClass.from(type).ts_type}"
      end
      "{ #{arg_types.join '; '} }"
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
      types, klasses = types.keys.partition { |t| t.is_a? Symbol }
      klasses << klass
      [types.sort, klasses.sort_by(&:name)]
    end

    def types
      types, klasses = collect_types
      scalar_types = types.map { |t| ScalarTypeClass.new t }
      klass_types = klasses.map { |t| SerializableTypeClass.new t }
      scalar_types + klass_types
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

    def collect_types(types); end

    def description
      ts_type
    end

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

    def self.from(type)
      type = [type[0...-1].to_sym, nil] if type.is_a?(Symbol) && type.to_s.ends_with?('?')
      type = [type[0...-1], nil] if type.is_a?(String) && type.ends_with?('?')
      case type
      when Class
        SerializableTypeClass.new type
      when Symbol, String, Numeric, true, false, nil
        ScalarTypeClass.new type
      when Array
        if type.size == 1
          ListTypeClass.new(type.first)
        elsif type.size == 2 && type.last.nil?
          OptionalTypeClass.new type
        else
          OrTypeClass.new type
        end
      when Hash
        HashTypeClass.new type
      end
    end
  end

  class ScalarTypeClass < TypeClass
    def kind
      'SCALAR'
    end

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
      else
        :any
      end
    end

    def collect_types(types)
      types[name] = true
    end

    def gql_type
      type
    end

    def ts_type
      case type
      when :int, :float
        'number'
      when :string, :number, :boolean
        type.to_s
      when Symbol
        'any'
      else
        type.to_json
      end
    end
  end

  class HashTypeClass < TypeClass
    def kind
      'SCALAR'
    end

    def name
      :other
    end

    def collect_types(types)
      types[:other] = true
      type.values.map do |v|
        TypeClass.from(v).collect_types(types)
      end
    end

    def association_type
      type.values.each do |v|
        t = TypeClass.from(v).association_type
        return t if t
      end
    end

    def gql_type
      'OBJECT'
    end

    def ts_type
      fields = type.map do |key, value|
        k = key.to_s == '*' ? '[key: string]' : key
        "#{k}: #{TypeClass.from(value).ts_type}"
      end
      "{ #{fields.join('; ')} }"
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

    def association_type
      self
    end

    def gql_type
      name
    end

    def ts_type
      "Type#{name}"
    end
  end

  class OptionalTypeClass < TypeClass
    def kind
      of_type.kind
    end

    def name
      of_type.name
    end

    def of_type
      TypeClass.from type.first
    end

    def association_type
      of_type.association_type
    end

    def collect_types(types)
      of_type.collect_types types
    end

    def gql_type
      of_type.gql_type
    end

    def ts_type
      "(#{of_type.ts_type} | null)"
    end
  end

  class OrTypeClass < TypeClass
    def kind
      'OBJECT'
    end

    def name
      'OBJECT'
    end

    def of_types
      type.map { |t| TypeClass.from t }
    end

    def collect_types(types)
      of_types.map { |t| t.collect_types types }
    end

    def gql_type
      kind
    end

    def ts_type
      '(' + of_types.map(&:ts_type).join(' | ') + ')'
    end
  end

  class ListTypeClass < TypeClass
    def kind
      'LIST'
    end

    def name
      'LIST'
    end

    def of_type
      TypeClass.from type
    end

    def collect_types(types)
      of_type.collect_types types
    end

    def association_type
      of_type.association_type
    end

    def gql_type
      "[#{of_type.gql_type}]"
    end

    def ts_type
      "(#{of_type.ts_type} [])"
    end
  end
end
