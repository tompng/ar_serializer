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
    serializer_field(:description) { '' }
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
    serializer_field(:isDeprecated) { false }
    serializer_field(:description) { '' }
    serializer_field(:deprecationReason) { nil }
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
      'NON_NULL'
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
end
