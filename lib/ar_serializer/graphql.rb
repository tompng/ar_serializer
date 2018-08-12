require 'graphql'
module ArSerializer::GraphQL
end

module ArSerializer::GraphQL::Types
  UndefinedType = GraphQL::ObjectType.define do
    name 'UndefinedType'
    field :this_is_an, types.String
    field :undefined_or_anonymous_type, types.String
  end

  def self.type_from_activemodel_type(type_class, name)
    case type_class
    when ActiveModel::Type::Float
      GraphQL::FLOAT_TYPE
    when ActiveModel::Type::Integer
      name.to_s.match?(/^(.+_)?id$/) ? GraphQL::ID_TYPE : GraphQL::INT_TYPE
    when ActiveModel::Type::Boolean
      GraphQL::BOOLEAN_TYPE
    else
      GraphQL::STRING_TYPE if type_class.class != ActiveModel::Type::Value
    end
  end

  def self.convert_type(type)
    case type
    when Symbol
      type_from_symbol type
    when GraphQL::BaseType
      type
    when Array
      raise if type.size != 1
      type_from_specified_type(type.first).to_list_type
    else
      if type.is_a?(Class) && type < ArSerializer::Serializable
        type_from_class type
      else
        UndefinedType
      end
    end
  end

  def self.type_from_symbol(sym)
    type_converts = {
      integer: GraphQL::INT_TYPE,
      float: GraphQL::FLOAT_TYPE,
      boolean: GraphQL::BOOLEAN_TYPE,
      string: GraphQL::STRING_TYPE,
      id: GraphQL::ID_TYPE,
      integer!: GraphQL::INT_TYPE.to_non_null_type,
      float!: GraphQL::FLOAT_TYPE.to_non_null_type,
      boolean!: GraphQL::BOOLEAN_TYPE.to_non_null_type,
      string!: GraphQL::STRING_TYPE.to_non_null_type,
      id!: GraphQL::ID_TYPE.to_non_null_type
    }
    return type_converts[sym] if type_converts.key? sym
    raise 'undefined type symbol'
  end

  def self.type_from_activerecord_field(klass, field_name)
    name = field_name.to_s.underscore
    association = klass.reflect_on_association name
    if association.nil?
      type_class = klass.attribute_types[name]
      return type_from_activemodel_type type_class, name if type_class
    end
    return if association.nil? || association.polymorphic?
    if association.collection?
      type_from_class(association.klass).to_list_type
    else
      type_from_class association.klass
    end
  end

  def self.prepare_type_for_class(klass)
    @type_from_class_definitions ||= {}
    @type_from_class_definitions[klass] ||= {
      type: GraphQL::ObjectType.define { name klass.name },
      klass: klass,
      definition: []
    }
  end

  def self.define_field(klass, name, type, association)
    el = prepare_type_for_class klass
    el[:definition] << [name, type, association]
  end

  def self.type_from_class(klass)
    el = prepare_type_for_class klass
    definitions = el[:definition]
    until definitions.empty?
      name, type, association = definitions.shift
      if type
        type = ArSerializer::GraphQL::Types.convert_type type
      elsif klass < ActiveRecord::Base
        type = ArSerializer::GraphQL::Types.type_from_activerecord_field klass, association || name
      end
      type ||= ArSerializer::GraphQL::Types::UndefinedType
      el[:type].define { field name, type }
    end
    el[:type]
  end
end

ArSerializer::Serializable::ClassMethods.class_eval do
  def serializer_field(*names, namespace: nil, association: nil, type: nil, **option, &data_block)
    namespaces = namespace.is_a?(Array) ? namespace : [namespace]
    namespaces.each do |ns|
      names.each do |name|
        field = ArSerializer::Field.create self, association || name, option, &data_block
        _serializer_namespace(ns)[name.to_s] = field
      end
    end
    names.each do |name|
      ArSerializer::GraphQL::Types.define_field self, name, type, association
    end
  end
end

__END__
class GQLQuery
  include ArSerializer::Serializable
  serializer_field(:profile, type: User){}
end
tmp_query_type = ArSerializer::GraphQL::Types.type_from_class(GQLQuery)
puts GraphQL::Schema.define { query tmp_query_type }.to_definition
