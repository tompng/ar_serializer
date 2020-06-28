require 'ar_serializer/version'
require 'ar_serializer/serializer'
require 'ar_serializer/field'
require 'active_record'

module ArSerializer
  def self.serialize(model, query, **option)
    Serializer.serialize(model, query, **option)
  end
end

module ArSerializer::Serializable
  extend ActiveSupport::Concern

  module ClassMethods
    def _serializer_namespace(ns)
      (@_serializer_field_info ||= {})[ns] ||= {}
    end

    def _serializer_field_info(name)
      ArSerializer::Serializer.current_namespaces.each do |ns|
        field = _serializer_namespace(ns)[name.to_s]
        return field if field
      end
      superclass._serializer_field_info name if superclass < ArSerializer::Serializable
    end

    def _serializer_field_keys
      keys = []
      ArSerializer::Serializer.current_namespaces.each do |ns|
        keys |= _serializer_namespace(ns).keys
      end
      keys |= superclass._serializer_field_keys if superclass < ArSerializer::Serializable
      keys
    end

    def serializer_field(*names, namespace: nil, association: nil, **option, &data_block)
      namespaces = namespace.is_a?(Array) ? namespace : [namespace]
      namespaces.each do |ns|
        names.each do |name|
          field = ArSerializer::Field.create(self, association || name, **option, &data_block)
          _serializer_namespace(ns)[name.to_s] = field
        end
      end
    end

    def _custom_preloaders
      @_custom_preloaders ||= {}
    end

    def define_preloader(name, &block)
      _custom_preloaders[name] = block
    end

    def serializer_defaults(**args, &block)
      serializer_field :defaults, **args, &block
    end
  end
end

ActiveRecord::Base.include ArSerializer::Serializable
ActiveRecord::Relation.include ArSerializer::ArrayLikeCompositeValue

require 'ar_serializer/graphql'
require 'ar_serializer/type_script'
