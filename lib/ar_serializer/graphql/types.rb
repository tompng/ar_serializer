module ArSerializer::GraphQL
  class ArgClass
    include ::ArSerializer::Serializable
    attr_reader :name, :type
    def initialize(name, type)
      @optional = name.to_s.end_with? '?' # TODO: refactor
      @name = name.to_s.delete '?'
      @type = TypeClass.from type
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
      return [] if field.arguments == :any
      field.arguments.map do |key, type|
        ArgClass.new key, type
      end
    end

    def type
      TypeClass.from field.type, field.only, field.except
    end

    def collect_types(types)
      types[:any] = true if field.arguments == :any
      args.each { |arg| arg.type.collect_types types }
      type.collect_types types
    end

    def args_required?
      return false if field.arguments == :any
      field.arguments.any? do |key, type|
        !key.match?(/\?$/) && !(type.is_a?(Array) && type.include?(nil))
      end
    end

    def args_ts_type
      return 'any' if field.arguments == :any
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
    attr_reader :type, :only, :except
    def initialize(type, only = nil, except = nil)
      @type = type
      @only = only
      @except = except
      validate!
    end

    class InvalidType < StandardError; end

    def validate!
      valid_symbols = %i[number int float string boolean any unknown]
      invalids = []
      recursive_validate = lambda do |t|
        case t
        when Array
          t.each { |v| recursive_validate.call v }
        when Hash
          t.each_value { |v| recursive_validate.call v }
        when String, Numeric, true, false, nil
          return
        when Class
          invalids << t unless t.ancestors.include? ArSerializer::Serializable
        when Symbol
          invalids << t unless valid_symbols.include? t.to_s.gsub(/\?$/, '').to_sym
        else
          invalids << t
        end
      end
      recursive_validate.call type
      return if invalids.empty?
      message = "Valid types are String, Numeric, Hash, Array, ArSerializer::Serializable, true, false, nil and Symbol#{valid_symbols}"
      raise InvalidType, "Invalid type: #{invalids.map(&:inspect).join(', ')}. #{message}"
    end

    def collect_types(types); end

    def description
      ts_type
    end

    def name; end

    def of_type; end

    def fields; end

    def sample; end

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
      type = [type[0...-1], nil] if type.is_a?(String) && type.end_with?('?')
      case type
      when Class
        SerializableTypeClass.new type, only, except
      when Symbol, String, Numeric, true, false, nil
        ScalarTypeClass.new type
      when Array
        if type.size == 1
          ListTypeClass.new type.first, only, except
        elsif type.size == 2 && type.last.nil?
          OptionalTypeClass.new type, only, except
        else
          OrTypeClass.new type, only, except
        end
      when Hash
        HashTypeClass.new type, only, except
      end
    end
  end

  class ScalarTypeClass < TypeClass
    def initialize(type)
      @type = type
    end

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
      when :unknown
        :unknown
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

    def sample
      case ts_type
      when 'number'
        0
      when 'string'
        ''
      when 'boolean'
        true
      when 'any', 'unknown'
        nil
      else
        type
      end
    end

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
    def kind
      'SCALAR'
    end

    def name
      :other
    end

    def collect_types(types)
      types[:other] = true
      type.values.map do |v|
        TypeClass.from(v, only, except).collect_types(types)
      end
    end

    def association_type
      type.values.each do |v|
        t = TypeClass.from(v, only, except).association_type
        return t if t
      end
      nil
    end

    def gql_type
      'OBJECT'
    end

    def sample
      type.reject { |k| k.to_s.end_with? '?' }.transform_values do |v|
        TypeClass.from(v).sample
      end
    end

    def ts_type
      fields = type.map do |key, value|
        k = key.to_s == '*' ? '[key: string]' : key
        "#{k}: #{TypeClass.from(value, only, except).ts_type}"
      end
      "{ #{fields.join('; ')} }"
    end
  end

  class SerializableTypeClass < TypeClass
    def field_only
      [*only].map(&:to_s)
    end

    def field_except
      [*except].map(&:to_s)
    end

    def kind
      'OBJECT'
    end

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

    def association_type
      self
    end

    def gql_type
      name
    end

    def ts_type
      "Type#{name}"
    end

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
    def kind
      of_type.kind
    end

    def name
      of_type.name
    end

    def of_type
      TypeClass.from type.first, only, except
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

    def sample
      nil
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
      :other
    end

    def of_types
      type.map { |t| TypeClass.from t, only, except }
    end

    def collect_types(types)
      types[:other] = true
      of_types.map { |t| t.collect_types types }
    end

    def gql_type
      kind
    end

    def sample
      of_types.first.sample
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
      TypeClass.from type, only, except
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

    def sample
      []
    end

    def ts_type
      "(#{of_type.ts_type} [])"
    end
  end
end
